#!/bin/bash


start_line=$(grep -n '#startweb' /etc/hosts | cut -d: -f 1)
if [[ $start_line == '' ]] ; then
	sudo echo "#startweb" >> /etc/hosts
	sudo echo ${1} >> /etc/hosts
	sudo echo "#endweb" >> /etc/hosts
else
	start_line2=$(($start_line+1))
	sudo sed -iz "${start_line2}s/.*/${1}/" /etc/hosts
	
fi
