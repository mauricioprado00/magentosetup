# updating the composer cache
if magento dependencies are changed, the cache will be invalid and it should be updated in this package.
Magento cached resources are in **config/composer/cache.tgz**. 
To update simply zip files from /home/${USER}/.composer/cache after **setup.sh** is run again.
