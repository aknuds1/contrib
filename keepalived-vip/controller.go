/*
Copyright 2015 The Kubernetes Authors All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"sort"
	"time"

	"github.com/golang/glog"

	"k8s.io/kubernetes/pkg/api"
	"k8s.io/kubernetes/pkg/client/cache"
	"k8s.io/kubernetes/pkg/client/unversioned"
	"k8s.io/kubernetes/pkg/controller/framework"
	"k8s.io/kubernetes/pkg/fields"
	"k8s.io/kubernetes/pkg/util"
	utildbus "k8s.io/kubernetes/pkg/util/dbus"
	"k8s.io/kubernetes/pkg/util/exec"
	"k8s.io/kubernetes/pkg/util/intstr"
	utiliptables "k8s.io/kubernetes/pkg/util/iptables"
)

const (
	reloadQPS    = 10.0
	resyncPeriod = 10 * time.Second
)

type service struct {
	IP   string
	Port int
}

type serviceByIPPort []service

func (c serviceByIPPort) Len() int      { return len(c) }
func (c serviceByIPPort) Swap(i, j int) { c[i], c[j] = c[j], c[i] }
func (c serviceByIPPort) Less(i, j int) bool {
	iIP := c[i].IP
	jIP := c[j].IP
	if iIP != jIP {
		return iIP < jIP
	}

	iPort := c[i].Port
	jPort := c[j].Port
	return iPort < jPort
}

type vip struct {
	Name     string
	IP       string
	Port     int
	Protocol string
	Backends []service
}

type vipByNameIPPort []vip

func (c vipByNameIPPort) Len() int      { return len(c) }
func (c vipByNameIPPort) Swap(i, j int) { c[i], c[j] = c[j], c[i] }
func (c vipByNameIPPort) Less(i, j int) bool {
	iName := c[i].Name
	jName := c[j].Name
	if iName != jName {
		return iName < jName
	}

	iIP := c[i].IP
	jIP := c[j].IP
	if iIP != jIP {
		return iIP < jIP
	}

	iPort := c[i].Port
	jPort := c[j].Port
	return iPort < jPort
}

// ipvsControllerController watches the kubernetes api and adds/removes
// services from LVS throgh ipvsadmin.
type ipvsControllerController struct {
	client            *unversioned.Client
	epController      *framework.Controller
	svcController     *framework.Controller
	svcLister         cache.StoreToServiceLister
	epLister          cache.StoreToEndpointsLister
	reloadRateLimiter util.RateLimiter
	keepalived        *keepalived
	configMapName     string
	ruCfg             []vip
	ruMD5             string
}

// getEndpoints returns a list of <endpoint ip>:<port> for a given service/target port combination.
func (ipvsc *ipvsControllerController) getEndpoints(
	s *api.Service, servicePort *api.ServicePort) []service {
	ep, err := ipvsc.epLister.GetServiceEndpoints(s)
	if err != nil {
		glog.Warningf("unexpected error getting service endpoints: %v", err)
		return []service{}
	}

	var endpoints []service

	// The intent here is to create a union of all subsets that match a targetPort.
	// We know the endpoint already matches the service, so all pod ips that have
	// the target port are capable of service traffic for it.
	for _, ss := range ep.Subsets {
		for _, epPort := range ss.Ports {
			var targetPort int
			switch servicePort.TargetPort.Type {
			case intstr.Int:
				if epPort.Port == servicePort.TargetPort.IntValue() {
					targetPort = epPort.Port
				}
			case intstr.String:
				if epPort.Name == servicePort.TargetPort.StrVal {
					targetPort = epPort.Port
				}
			}
			if targetPort == 0 {
				continue
			}
			for _, epAddress := range ss.Addresses {
				endpoints = append(endpoints, service{IP: epAddress.IP, Port: targetPort})
			}
		}
	}

	return endpoints
}

// getServices returns a list of services and their endpoints.
func (ipvsc *ipvsControllerController) getServices() []vip {
	svcs := []vip{}

	ns, name, err := parseNsName(ipvsc.configMapName)
	if err != nil {
		glog.Warningf("%v", err)
		return []vip{}
	}
	cfgMap, err := ipvsc.getConfigMap(ns, name)
	if err != nil {
		glog.Warningf("%v", err)
		return []vip{}
	}

	// k -> IP to use
	// v -> <namespace>/<service name>:<port from service to be used>
	for externalIP, nsSvc := range cfgMap.Data {
		_, _, err := parseNsName(nsSvc)
		if err != nil {
			glog.Warningf("%v", err)
			continue
		}

		svcObj, svcExists, err := ipvsc.svcLister.Store.GetByKey(nsSvc)
		if err != nil {
			glog.Warningf("error getting service %v: %v", nsSvc, err)
			continue
		}

		if !svcExists {
			glog.Warningf("service %v not found", nsSvc)
			continue
		}

		s := svcObj.(*api.Service)
		for _, servicePort := range s.Spec.Ports {
			ep := ipvsc.getEndpoints(s, &servicePort)
			if len(ep) == 0 {
				glog.Warningf("no endpoints found for service %v, port %+v", s.Name, servicePort)
				continue
			}

			sort.Sort(serviceByIPPort(ep))

			svcs = append(svcs, vip{
				Name:     fmt.Sprintf("%v/%v", s.Namespace, s.Name),
				IP:       externalIP,
				Port:     servicePort.Port,
				Backends: ep,
				Protocol: fmt.Sprintf("%v", servicePort.Protocol),
			})
			glog.V(2).Infof("found service: %v:%v", s.Name, servicePort.Port)
		}
	}

	sort.Sort(vipByNameIPPort(svcs))

	return svcs
}

func (ipvsc *ipvsControllerController) getConfigMap(ns, name string) (*api.ConfigMap, error) {
	return ipvsc.client.ConfigMaps(ns).Get(name)
}

// sync all services with the
func (ipvsc *ipvsControllerController) sync() {
	ipvsc.reloadRateLimiter.Accept()

	if !ipvsc.epController.HasSynced() || !ipvsc.svcController.HasSynced() {
		time.Sleep(100 * time.Millisecond)
		return
	}

	svc := ipvsc.getServices()
	ipvsc.ruCfg = svc

	err := ipvsc.keepalived.WriteCfg(svc)
	if err != nil {
		return
	}
	glog.V(2).Infof("services: %v", svc)

	md5, err := checksum(keepalivedCfg)
	if err == nil && md5 == ipvsc.ruMD5 {
		return
	}

	ipvsc.ruMD5 = md5
	err = ipvsc.keepalived.Reload()
	if err != nil {
		glog.Errorf("error reloading keepalived: %v", err)
	}
}

// newIPVSController creates a new controller from the given config.
func newIPVSController(kubeClient *unversioned.Client, namespace string, useUnicast bool, configMapName string) *ipvsControllerController {
	ipvsc := ipvsControllerController{
		client:            kubeClient,
		reloadRateLimiter: util.NewTokenBucketRateLimiter(reloadQPS, int(reloadQPS)),
		ruCfg:             []vip{},
		configMapName:     configMapName,
	}

	clusterNodes := getClusterNodesIP(kubeClient)

	nodeInfo, err := getNodeInfo(clusterNodes)
	if err != nil {
		glog.Fatalf("Error getting local IP from nodes in the cluster: %v", err)
	}

	neighbors := getNodeNeighbors(nodeInfo, clusterNodes)

	execer := exec.New()
	dbus := utildbus.New()
	iptInterface := utiliptables.New(execer, dbus, utiliptables.ProtocolIpv4)

	ipvsc.keepalived = &keepalived{
		iface:      nodeInfo.iface,
		ip:         nodeInfo.ip,
		netmask:    nodeInfo.netmask,
		nodes:      clusterNodes,
		neighbors:  neighbors,
		priority:   getNodePriority(nodeInfo.ip, clusterNodes),
		useUnicast: useUnicast,
		ipt:        iptInterface,
	}

	err = ipvsc.keepalived.loadTemplate()
	if err != nil {
		glog.Fatalf("Error loading keepalived template: %v", err)
	}

	eventHandlers := framework.ResourceEventHandlerFuncs{}

	ipvsc.svcLister.Store, ipvsc.svcController = framework.NewInformer(
		cache.NewListWatchFromClient(
			ipvsc.client, "services", namespace, fields.Everything()),
		&api.Service{}, resyncPeriod, eventHandlers)

	ipvsc.epLister.Store, ipvsc.epController = framework.NewInformer(
		cache.NewListWatchFromClient(
			ipvsc.client, "endpoints", namespace, fields.Everything()),
		&api.Endpoints{}, resyncPeriod, eventHandlers)

	return &ipvsc
}

func checksum(filename string) (string, error) {
	var result []byte
	file, err := os.Open(filename)
	if err != nil {
		return "", err
	}
	defer file.Close()

	hash := md5.New()
	_, err = io.Copy(hash, file)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(result)), nil
}
