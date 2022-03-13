#!/bin/sh


start_line=$(grep -n '#startweb' /etc/hosts | cut -d: -f 1)
if [ $start_line=='' ];then
	sudo echo "#startweb" >> /etc/hosts
	sudo echo ${1} >> /etc/hosts
	sudo echo "#endweb" >> /etc/hosts
else
	echo 'no'
	exit 0
	start_line=$(($start_line+1))
	sudo sed -iz "${start_line}s/.*/${1}/" /etc/hosts
	
fi
