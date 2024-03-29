## Load Balancing CyberArk Servers

There are several services in CyberArk products that requires load balancing:

| CyberArk Server | Description |
| --- | --- |
| Password Vault Web Access (PVWA)  | Web console for CyberArk PAM |
| Privilege Session Manager (PSM)  | Jump host and session recording for CyberArk PAM |
| PSM Gateway (PSMGW)  | Placed in front of PSM to deliver sessions in browser windows, a.k.a. HTML5 Gateway  |
| Central Credential Provider (CCP) | CyberArk Secrets Manager for static, monolithic, traditional, and COTS applications |
| Conjur | CyberArk Secrets Manager for DevOps and CI/CD applications |

![image](https://github.com/joetanx/load-balancing-cyberark/assets/90442032/f02a00ef-c5f9-43de-a97c-e8179f13b133)

- For development environments or small-to-mid enterprise environments, deploying state-of-the-art Application Delivery Controllers (ADCs) may not be an optimized solution.
- This guide provides an overview on how open source software can help to load balance CyberArk Servers

### Lab Environment

#### Software Versions

|Software|Version|
|---|---|
|CyberArk PAM|12.2|
|CyberArk CCP|12.2|
|Conjur|12.5|
|Load Balancer OS|RHEL 8.5|
|keepalived|2.1.5|
|nginx|1.14.1|

#### Servers/Networking

|Function|Hostname|IP Address|
|---|---|---|
|LB|lb{1..2}.vx|192.168.0.{91..92}|
|PVWA VIP|pvwa.vx|192.168.0.10|
|PVWA|pvwa{1..3}.vx|192.168.0.{11..13}|
|PSM VIP|psm.vx|192.168.0.20|
|PSM|psm{1..3}.vx|192.168.0.{21..23}|
|PSMGW VIP|psmgw.vx|192.168.0.30|
|PSMGW|psmgw{1..3}.vx|192.168.0.{31..33}|
|CCP VIP|ccp.vx|192.168.0.40|
|CCP|ccp{1..3}.vx|192.168.0.{41..43}|
|Conjur VIP|conjur.vx|192.168.0.50|
|Conjur|conjur{1..3}.vx|192.168.0.{51..53}|

## 1. Keepalived Setup

Keepalived provides high availability capabilities to automatically failover the virtual services in event of a node failure

- Keepalived uses virtual router redundancy protocol (VRRP) to assign the virtual IP to the master node
- Keepalived can optionally create Linux Virtual Server (LVS) to perform load balancing, but NGINX or HAProxy is usually chosen for their expansive load balancing options, e.g. HTTP SSL termination
- The NGINX service listens on the virtual IPs managed by keepalived

Ref:

- <https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/load_balancer_administration/ch-keepalived-overview-vsa>
- <https://docs.nginx.com/nginx/admin-guide/high-availability/ha-keepalived/>

### 1.1. Install keepalived on both nodes

```console
yum -y install keepalived
```

Edit the keepalived config file `/etc/keepalived/keepalived.conf` **on both nodes**:

- The respective reference config files for master and backup nodes are in the next [Keepalived Configuration Files Section](#12-keepalived-configuration-files)

```console
mv /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.bak
vi /etc/keepalived/keepalived.conf
```

### 1.2. Keepalived Configuration Files

#### 1.2.1. Master Node Configuration

https://github.com/joetanx/load-balancing-cyberark/blob/3f6d3e20c8f87e81a4f6d59d4d7e5b09c405b1fc/keepalived-master.conf#L1-L35

#### 1.2.2. Backup Node Configuration

https://github.com/joetanx/load-balancing-cyberark/blob/14fc9c13af50a1e13c543fd1cbea6b4295c8f2fb/keepalived-backup.conf#L1-L35

### 1.3. Prepare the Notification and Tracking Scripts

The load balancer pair in this guide has serveral services on HTTPS (PVWA, PSMGW, CCP, Conjur), this means the NGINX configuration needs to listen on the respective virtual IP rather than `0.0.0.0`. Hence, the scripts provided below behaves as such:

- Tracking script verify if the node is able to reach the virtual IP
- Notification script starts the NGINX service if the node changes to `MASTER`, and stops the NGINX services if the changes to `BACKUP` or `FAULT

If the load balancer is meant for only 1 service:

- The NGINX configuration can be changed to listen on `0.0.0.0`
- The NGINX service can be active on both nodes
- The NGINX and the tracking and nofication scripts can be modified to be much simpler

> **Warning**: keepalived scripts should be placed in `/usr/libexec/keepalived/` where the correct SELinux file context `keepalived_unconfined_script_t` is assigned
>
> - Trying to get keepalive to run scripts from elsewhere may result in `permission denied` errors
>
> - Google for `keepalive setenforce 0` and you find that many guides disable SELinux - this script-doesn't-run behaviour is one of the reasons for disabling SELinux

#### 1.3.1. Tracking Script

Prepare the HA check script **on both nodes**:

```console
vi /usr/libexec/keepalived/nginx-ha-check.sh
```

The HA check script will `curl` to the PVWA virtual IP - this script returns `0` if curl is successful:

https://github.com/joetanx/load-balancing-cyberark/blob/871361fff6b76e637de7ab7c3f949fbad727f285/nginx-ha-check.sh#L1-L3

Add executable permission to script:

```console
chmod +x /usr/libexec/keepalived/nginx-ha-check.sh
```

#### 1.3.2. Notification Script

Prepare the HA notify script **on both nodes**:

```console
vi /usr/libexec/keepalived/nginx-ha-notify.sh
```

The HA notify script will start the nginx service when the node state changes to master, and stop the nginx service when the node state changes to backup or fault:

https://github.com/joetanx/load-balancing-cyberark/blob/871361fff6b76e637de7ab7c3f949fbad727f285/nginx-ha-notify.sh#L1-L20

Add executable permission to script:

```console
chmod +x /usr/libexec/keepalived/nginx-ha-notify.sh
```

### 1.4. Start Keepalived

Allow VRRP communication through firewall and start keepalived service **on both nodes**:

```console
firewall-cmd --add-rich-rule='rule protocol value="vrrp" accept' --permanent
firewall-cmd --reload
systemctl enable --now keepalived
```

<details><summary><h2>2. Preparing certificates</h2></summary>

### 2.1. Generate a self-signed certificate authority

#### Method 1 - Generate key first, then CSR, then certificate

Generate private key of the self-signed certificate authority:

```console
[root@ccyberark ~]# openssl genrsa -out cacert.key 2048
Generating RSA private key, 2048 bit long modulus (2 primes)
...........................................................................+++++
.......................................+++++
e is 65537 (0x010001)
```

Generate certificate of the self-signed certificate authority:

> **Note**: change the common name of the certificate according to your environment

```console
[root@ccyberark ~]# openssl req -x509 -new -nodes -key cacert.key -days 365 -sha256 -out cacert.pem
You are about to be asked to enter information that will be incorporated
into your certificate request.
What you are about to enter is what is called a Distinguished Name or a DN.
There are quite a few fields but you can leave some blank
For some fields there will be a default value,
If you enter '.', the field will be left blank.
-----
Country Name (2 letter code) [XX]:.
State or Province Name (full name) []:
Locality Name (eg, city) [Default City]:.
Organization Name (eg, company) [Default Company Ltd]:.
Organizational Unit Name (eg, section) []:
Common Name (eg, your name or your server's hostname) []:vx Lab Certificate Authority
Email Address []:
```

#### Method 2 - Generate key and certificate in a single command

```console
[root@ccyberark ~]# openssl req -newkey rsa:2048 -days "365" -nodes -x509 -keyout cacert.key -out cacert.pem
Generating a RSA private key
...............................................+++++
.........+++++
writing new private key to 'cacert.key'
-----
You are about to be asked to enter information that will be incorporated
into your certificate request.
What you are about to enter is what is called a Distinguished Name or a DN.
There are quite a few fields but you can leave some blank
For some fields there will be a default value,
If you enter '.', the field will be left blank.
-----
Country Name (2 letter code) [XX]:.
State or Province Name (full name) []:
Locality Name (eg, city) [Default City]:.
Organization Name (eg, company) [Default Company Ltd]:.
Organizational Unit Name (eg, section) []:
Common Name (eg, your name or your server's hostname) []:vx Lab Certificate Authority
Email Address []:
```

### 2.2. Generate PVWA certificates

```console
openssl genrsa -out pvwa.key 2048
openssl req -new -key pvwa.key -subj "/CN=CyberArk Password Vault Web Access" -out pvwa.csr
echo "subjectAltName=DNS:pvwa.vx,DNS:pvwa1.vx,DNS:pvwa2.vx,DNS:pvwa3.vx" > pvwa-openssl.cnf
openssl x509 -req -in pvwa.csr -CA cacert.pem -CAkey cacert.key -CAcreateserial -days 365 -sha256 -out pvwa.pem -extfile pvwa-openssl.cnf
```

### 2.3. Generate PSMGW certificates

```console
openssl genrsa -out psmgw.key 2048
openssl req -new -key psmgw.key -subj "/CN=CyberArk HTML5 Gateway" -out psmgw.csr
echo "subjectAltName=DNS:psmgw.vx,DNS:psmgw1.vx,DNS:psmgw2.vx,DNS:psmgw3.vx" > psmgw-openssl.cnf
openssl x509 -req -in psmgw.csr -CA cacert.pem -CAkey cacert.key -CAcreateserial -days 365 -sha256 -out psmgw.pem -extfile psmgw-openssl.cnf
```

### 2.4. Generate CCP certificates

```console
openssl genrsa -out ccp.key 2048
openssl req -new -key ccp.key -subj "/CN=CyberArk Central Credential Provider" -out ccp.csr
echo "subjectAltName=DNS:ccp.vx,DNS:ccp1.vx,DNS:ccp2.vx,DNS:ccp3.vx" > ccp-openssl.cnf
openssl x509 -req -in ccp.csr -CA cacert.pem -CAkey cacert.key -CAcreateserial -days 365 -sha256 -out ccp.pem -extfile ccp-openssl.cnf
```

### 2.5. Generate Conjur certificates

```console
openssl genrsa -out conjur.key 2048
openssl req -new -key conjur.key -subj "/CN=CyberArk Conjur" -out conjur.csr
echo "subjectAltName=DNS:conjur.vx,DNS:conjur-master.vx,DNS:conjur-standby1.vx,DNS:conjur-standby2.vx," > conjur-openssl.cnf
openssl x509 -req -in conjur.csr -CA cacert.pem -CAkey cacert.key -CAcreateserial -days 365 -sha256 -out conjur.pem -extfile conjur-openssl.cnf
```

</details>

## 3. NGINX Setup

NGINX provides reverse proxy and load balancing capabilities to broker connection to, and handle failures for backend CyberArk servers

- A server block is configured for each virtual service, listening on the virtual IP managed by keepalived
- NGINX `http` module: for HTTP-based services (PVWA, PSMGW, CCP and Conjur), enables SSL termination
- NGINX `stream` module: for TCP/UDP-based services (PVWA, PSM, PSMGW, CCP and Conjur), straightforward SSL passthrough

Ref:

- <https://docs.nginx.com/nginx/admin-guide/load-balancer/http-load-balancer/>
- <https://docs.nginx.com/nginx/admin-guide/security-controls/terminating-ssl-tcp/>
- <https://docs.nginx.com/nginx/admin-guide/load-balancer/tcp-udp-load-balancer/>

Install NGINX, enable NGINX to listen on ports in SELinux, add firewall rules:

```console
yum -y install nginx nginx-mod-stream
setsebool -P httpd_can_network_connect on
firewall-cmd --permanent --add-service https && firewall-cmd --reload
```

Edit the NGINX listener and load balancing config file `/etc/nginx/nginx.conf`:

- The respective reference config files for PVWA, PSM, PSMGW, CCP and Conjur are in below [NGINX Configuration Files Section](#22-nginx-configuration-files)

```console
mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
vi /etc/nginx/nginx.conf
nginx -t
```

> **Note**: Do not start or enable the nginx service, the nginix service start/stop are controlled by `nginx-ha-notify` script in keepalived

### 3.1. PVWA

#### Configurations on PVWA servers to capture client IP address

Configure `HTTP_X_Forwarded_For` on PVWA servers - edit `C:\inetpub\wwwroot\PasswordVault\web.config`:

```xml
  <appSettings>
    ⋮
    <add key="LoadBalancerClientAddressHeader" value="HTTP_X_Forwarded_For" />
  </appSettings>
```

#### SSL Termination

> **Warning**: Certificate authentication does not work with SSL Terminated load balancing, use SSL Passthrough if certificate authentication is required

https://github.com/joetanx/load-balancing-cyberark/blob/871361fff6b76e637de7ab7c3f949fbad727f285/nginx-pvwa-http.conf#L1-L34

#### SSL Passthrough

https://github.com/joetanx/load-balancing-cyberark/blob/871361fff6b76e637de7ab7c3f949fbad727f285/nginx-pvwa-stream.conf#L1-L13

### 3.2. PSM

#### Allow NGINX to listen on RDP port

Attempting to bind to ports other than other listed on `http_port_t` will result in `permission denied` because of SELinux, add the required ports to `http_port_t` to enable binding on them

```console
yum install -y policycoreutils-python-utils
semanage port -a -t http_port_t -p tcp 3389
```

#### SSL Termination

Not Supported

#### SSL Passthrough

https://github.com/joetanx/load-balancing-cyberark/blob/871361fff6b76e637de7ab7c3f949fbad727f285/nginx-psm-stream.conf#L1-L13

### 3.3. PSMGW

#### SSL Termination

Ref: <https://guacamole.apache.org/doc/1.4.0/gug/reverse-proxy.html>

https://github.com/joetanx/load-balancing-cyberark/blob/871361fff6b76e637de7ab7c3f949fbad727f285/nginx-psmgw-http.conf#L1-L38

#### SSL Passthrough

https://github.com/joetanx/load-balancing-cyberark/blob/871361fff6b76e637de7ab7c3f949fbad727f285/nginx-psmgw-stream.conf#L1-L13

### 3.4. CCP

#### Configurations on CCP servers to capture client IP address

Configure `HTTP_X_Forwarded_For` on CCP servers - edit `C:\inetpub\wwwroot\AIMWebService\web.config`:

```xml
  <appSettings>
    ⋮
    <add key="TrustedProxies" value="192.168.0.40"/>
    <add key="LoadBalancerClientAddressHeader" value="HTTP_X_Forwarded_For" />
  </appSettings>
```

#### SSL Termination

> **Warning**: Certificate authentication does not work with SSL Terminated load balancing, use SSL Passthrough if certificate authentication is required

https://github.com/joetanx/load-balancing-cyberark/blob/871361fff6b76e637de7ab7c3f949fbad727f285/nginx-ccp-http.conf#L1-L34

#### SSL Passthrough

https://github.com/joetanx/load-balancing-cyberark/blob/871361fff6b76e637de7ab7c3f949fbad727f285/nginx-ccp-stream.conf#L1-L13

### 3.5. Conjur

#### Configurations on Conjur servers to capture client IP address (for SSL Terminated load balancing)
```console
podman exec conjur evoke proxy add 192.168.0.50
```

#### Allow NGINX to listen on PostgreSQL port

Attempting to bind to ports other than other listed on `http_port_t` will result in `permission denied` because of SELinux, add the required ports to `http_port_t` to enable binding on them

Notice that `-m` modify is used here in contrast to `-a` add used in above PSM configuration, this is because port `5432` is already configured for `postgresql_port_t`

```console
yum install -y policycoreutils-python-utils
semanage port -m -t http_port_t -p tcp 5432
```

#### SSL Termination

> **Warning**:
>
> The NGINX `http` module doesn't work very well for Conjur:
> - CSR functions on `authn-k8s` does not work with SSL Terminated load balancing
> - HTTP-based proxy cannot work with PostgreSQL replication
>
> This `http` module based configuration only works for the Conjur UI and basic API functions (such as `authn`)
>
> Thus, the `stream` module based configuration below may be more suitable in most environments

https://github.com/joetanx/load-balancing-cyberark/blob/871361fff6b76e637de7ab7c3f949fbad727f285/nginx-conjur-http.conf#L1-L34

##### SSL Passthrough

https://github.com/joetanx/load-balancing-cyberark/blob/871361fff6b76e637de7ab7c3f949fbad727f285/nginx-conjur-stream.conf#L1-L22
