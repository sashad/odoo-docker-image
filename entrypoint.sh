#!/bin/bash
#
sudo /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
sudo chown -R odoo:odoo /var/lib/odoo
sudo chown odoo:odoo /mnt/extra-addons
cd vendor/OCA/OCB/
source ~/.venv/bin/activate
./odoo-bin

