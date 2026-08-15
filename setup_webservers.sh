#!/bin/bash

# بروزرسانی لیست پکیج‌ها
echo "Updating package lists..."
sudo apt update

# نصب پیش‌نیازها
sudo apt install -y software-properties-common ca-certificates

# ۱. اضافه کردن رپوزیتوری‌ها
echo "Adding repositories for PHP, Nginx, and Apache..."
sudo add-apt-repository ppa:ondrej/php -y
sudo add-apt-repository ppa:nginx/stable -y
sudo add-apt-repository ppa:ondrej/apache2 -y

# بروزرسانی مخازن جدید
sudo apt update

# ۲. نصب Apache و Nginx
echo "Installing Apache and Nginx..."
sudo apt install -y apache2 nginx

# ۳. تغییر پورت Nginx از 80 به 8080
echo "Configuring Nginx to use port 8080..."
# این دستور در فایل تنظیمات پیش‌فرض، پورت 80 را پیدا کرده و به 8080 تغییر می‌دهد
sudo sed -i 's/listen 80 default_server;/listen 8080 default_server;/g' /etc/nginx/sites-available/default
sudo sed -i 's/listen \[::\]:80 default_server;/listen \[::\]:8080 default_server;/g' /etc/nginx/sites-available/default

# ۴. فعال‌سازی سرویس‌ها برای اجرا در هنگام بوت (Persistency)
echo "Enabling services for auto-start on boot..."
sudo systemctl enable apache2
sudo systemctl enable nginx

# ۵. ری‌استارت سرویس‌ها برای اعمال تغییرات
echo "Restarting services..."
sudo systemctl restart apache2
sudo systemctl restart nginx

# ۶. بررسی نهایی
echo "------------------------------------------------"
echo "Check Status:"
echo "Apache is running on port 80"
echo "Nginx is running on port 8080"
echo "------------------------------------------------"
sudo netstat -tulpn | grep -E 'apache2|nginx'
