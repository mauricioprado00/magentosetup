# Magento credentials
- [Get your authentication keys](https://devdocs.magento.com/guides/v2.3/install-gde/prereq/connect-auth.html)
# create new magento
```bash
mkdir /yourmagentopath
pushd /yourmagentopah
~1/setup.sh
```
# using the generated installation
after the setup you will have a working docker environment, and you will receive a message like:
```
magento is already installed
- Magento system http://testingmag2.localhost/admin_1smi7q user: admin password: Admin123
- Phpmyadmin http://localhost:8081 user:root password: root
- Mailserver http://localhost:1080
```

you can modify the parameters of the environment varibles in the `.env` file