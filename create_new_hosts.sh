#!/bin/sh


start_line=$(grep -n '#startweb' /etc/hosts | cut -d: -f 1)
start_line=$(($start_line+1))
sudo sed -iz "${start_line}s/.*/${1}/" /etc/hosts