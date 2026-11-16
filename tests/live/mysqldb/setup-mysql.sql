-- Users for each authentication plugin the client speaks (MySQL 8.4,
-- started with --mysql-native-password=ON).
CREATE USER 'native'@'%' IDENTIFIED WITH mysql_native_password BY 'native-pw';
CREATE USER 'sha2'@'%' IDENTIFIED WITH caching_sha2_password BY 'sha2-pw';
CREATE USER 'sha256'@'%' IDENTIFIED WITH sha256_password BY 'sha256-pw';
CREATE USER 'nopw'@'%' IDENTIFIED WITH caching_sha2_password BY '';
GRANT ALL ON slangtest.* TO 'native'@'%', 'sha2'@'%', 'sha256'@'%', 'nopw'@'%';
GRANT PROCESS, CONNECTION_ADMIN ON *.* TO 'sha2'@'%';
