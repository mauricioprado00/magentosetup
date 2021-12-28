# Magento credentials
- [Get your authentication keys](https://devdocs.magento.com/guides/v2.3/install-gde/prereq/connect-auth.html)
# create new magento
```bash
mkdir /yourmagentopath
pushd /yourmagentopah
~1/setup.sh
```
# updating the composer cache
if magento dependencies are changed, the cache will be invalid and it should be updated in this package.
Magento cached resources are in **config/composer/cache.tgz**. 
To update simply zip files from /home/${USER}/.composer/cache after **setup.sh** is run again.
