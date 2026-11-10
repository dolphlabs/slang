-- MariaDB's default plugin is mysql_native_password.
CREATE USER 'native'@'%' IDENTIFIED BY 'native-pw';
GRANT ALL ON slangtest.* TO 'native'@'%';
