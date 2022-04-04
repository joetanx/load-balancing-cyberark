# Overview
![image](images/architecture.png)

# Keepalived Configuration

# NGINX Configuration

```console
yum -y install nginx
setsebool -P httpd_can_network_connect on
firewall-cmd --permanent --add-service https && firewall-cmd --reload
mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
vi /etc/nginx/nginx.conf
nginx -t
systemctl enable --now nginx
```

## Generating SSL certificates

### Generate a self-signed certificate authority

<details>
<summary>Method 1- Generate key first, then CSR, then certificate</summary>

```console
[root@ccyberark ~]# openssl genrsa -out cacert.key 2048
Generating RSA private key, 2048 bit long modulus (2 primes)
...........................................................................+++++
.......................................+++++
e is 65537 (0x010001)
```
- Generate certificate of the self-signed certificate authority
- **Note**: change the common name of the certificate according to your environment
```console
[root@conjur ~]# openssl req -x509 -new -nodes -key cacert.key -days 365 -sha256 -out cacert.pem
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

</details>

<details>
<summary>Method 2 - Generate key and certificate in a single command</summary>

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

</details>

### Generate PVWA certificates

```console
openssl genrsa -out pvwa.key 2048
openssl req -new -key pvwa.key -subj "/CN=CyberArk Password Vault Web Access" -out pvwa.csr
echo "subjectAltName=DNS:pvwa.vx,DNS:pvwa1.vx,DNS:pvwa2.vx,DNS:pvwa3.vx" > pvwa-openssl.cnf
openssl x509 -req -in pvwa.csr -CA cacert.pem -CAkey cacert.key -CAcreateserial -days 365 -sha256 -out pvwa.pem -extfile pvwa-openssl.cnf
```

### Generate PSMGW certificates

```console
openssl genrsa -out psmgw.key 2048
openssl req -new -key psmgw.key -subj "/CN=CyberArk HTML5 Gateway" -out psmgw.csr
echo "subjectAltName=DNS:psmgw.vx,DNS:psmgw1.vx,DNS:psmgw2.vx,DNS:psmgw3.vx" > psmgw-openssl.cnf
openssl x509 -req -in psmgw.csr -CA cacert.pem -CAkey cacert.key -CAcreateserial -days 365 -sha256 -out psmgw.pem -extfile psmgw-openssl.cnf
```

### Generate CCP certificates

```console
openssl genrsa -out ccp.key 2048
openssl req -new -key ccp.key -subj "/CN=CyberArk Central Credential Provider" -out ccp.csr
echo "subjectAltName=DNS:ccp.vx,DNS:ccp1.vx,DNS:ccp2.vx,DNS:ccp3.vx" > ccp-openssl.cnf
openssl x509 -req -in ccp.csr -CA cacert.pem -CAkey cacert.key -CAcreateserial -days 365 -sha256 -out ccp.pem -extfile ccp-openssl.cnf
```

### Generate Conjur certificates

```console
openssl genrsa -out conjur.key 2048
openssl req -new -key conjur.key -subj "/CN=CyberArk Conjur" -out conjur.csr
echo "subjectAltName=DNS:conjur.vx,DNS:conjur-master.vx,DNS:conjur-standby1.vx,DNS:conjur-standby2.vx," > conjur-openssl.cnf
openssl x509 -req -in conjur.csr -CA cacert.pem -CAkey cacert.key -CAcreateserial -days 365 -sha256 -out conjur.pem -extfile conjur-openssl.cnf
```

## PVWA

<details>
<summary>Configurations on PVWA servers to capture client IP address</summary>

Configure `HTTP_X_Forwarded_For` on PVWA servers - edit `C:\inetpub\wwwroot\PasswordVault\web.config`

```
  <appSettings>
    ••• other configurations •••
    <add key="LoadBalancerClientAddressHeader" value="HTTP_X_Forwarded_For" />
  </appSettings>
```

</details>

<details>
<summary>SSL Termination</summary>

☝️ **Note**: Certificate authentication does not work with SSL Terminated load balancing, use SSL Passthrough if certificate authentication is required

```
events {}
http {
  upstream pvwa {
    server 192.168.17.11:443;
    server 192.168.17.12:443;
    server 192.168.17.13:443;
  }
  server {
    listen 192.168.17.10:443 ssl;
    server_name pvwa.vx

    ssl on;
    ssl_certificate         /etc/nginx/ssl/pvwa.pem;
    ssl_certificate_key     /etc/nginx/ssl/pvwa.key;
    ssl_trusted_certificate /etc/nginx/ssl/cacert.pem;

    ssl_session_cache shared:SSL:20m;
    ssl_session_timeout 10m;

    ssl_prefer_server_ciphers on;
    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_ciphers               HIGH:!aNULL:!MD5;

    add_header Strict-Transport-Security "max-age=31536000";

    location / {
      proxy_pass https://pvwa;
      proxy_set_header Host              $host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }
  }
}
```

</details>

<details>
<summary>SSL Passthrough</summary>

```
load_module /usr/lib64/nginx/modules/ngx_stream_module.so;
events {}
stream {
  upstream pvwa {
    server 192.168.17.11:443;
    server 192.168.17.12:443;
    server 192.168.17.13:443;
  }
  server {
    listen 192.168.17.10:443;
    proxy_pass pvwa;
  }
}
```

</details>

## PSM

<details>
<summary>SSL Termination - Not Supported</summary>
</details>

<details>
<summary>SSL Passthrough</summary>

```
load_module /usr/lib64/nginx/modules/ngx_stream_module.so;
events {}
stream {
  upstream psm {
    server 192.168.17.21:3389;
    server 192.168.17.22:3389;
    server 192.168.17.23:3389;
  }
  server {
    listen 192.168.17.20:3389;
    proxy_pass psm;
  }
}
```

</details>

## PSMGW

Ref: <https://guacamole.apache.org/doc/1.4.0/gug/reverse-proxy.html>

<details>
<summary>SSL Termination</summary>

```
events {}
http {
  upstream psmgw {
    server 192.168.17.31:443;
    server 192.168.17.32:443;
    server 192.168.17.33:443;
  }
  server {
    listen 192.168.17.30:443 ssl;
    server_name psmgw.vx

    ssl on;
    ssl_certificate         /etc/nginx/ssl/psmgw.pem;
    ssl_certificate_key     /etc/nginx/ssl/psmgw.key;
    ssl_trusted_certificate /etc/nginx/ssl/cacert.pem;

    ssl_session_cache shared:SSL:20m;
    ssl_session_timeout 10m;

    ssl_prefer_server_ciphers on;
    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_ciphers               HIGH:!aNULL:!MD5;

    add_header Strict-Transport-Security "max-age=31536000";

    location / {
      proxy_pass https://psmgw;
      proxy_set_header Host              $host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_buffering off;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $http_connection;
    }
  }
}
```

</details>

<details>
<summary>SSL Passthrough</summary>

```
load_module /usr/lib64/nginx/modules/ngx_stream_module.so;
events {}
stream {
  upstream psmgw {
    server 192.168.17.31:443;
    server 192.168.17.32:443;
    server 192.168.17.33:443;
  }
  server {
    listen 192.168.17.30:443;
    proxy_pass psmgw;
  }
}
```

</details>

## CCP

<details>
<summary>Configurations on CCP servers to capture client IP address</summary>

Configure `HTTP_X_Forwarded_For` on CCP servers - edit `C:\inetpub\wwwroot\AIMWebService\web.config`

```
  <appSettings>
    ••• other configurations •••
    <add key="TrustedProxies" value="192.168.0.40"/>
    <add key="LoadBalancerClientAddressHeader" value="HTTP_X_Forwarded_For" />
  </appSettings>
```

</details>

<details>
<summary>SSL Termination</summary>

☝️ **Note**: Certificate authentication does not work with SSL Terminated load balancing, use SSL Passthrough if certificate authentication is required

```
events {}
http {
  upstream ccp {
    server 192.168.17.41:443;
    server 192.168.17.42:443;
    server 192.168.17.43:443;
  }
  server {
    listen 192.168.17.40:443 ssl;
    server_name ccp.vx

    ssl on;
    ssl_certificate         /etc/nginx/ssl/ccp.pem;
    ssl_certificate_key     /etc/nginx/ssl/ccp.key;
    ssl_trusted_certificate /etc/nginx/ssl/cacert.pem;

    ssl_session_cache shared:SSL:20m;
    ssl_session_timeout 10m;

    ssl_prefer_server_ciphers on;
    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_ciphers               HIGH:!aNULL:!MD5;

    add_header Strict-Transport-Security "max-age=31536000";

    location / {
      proxy_pass https://ccp;
      proxy_set_header Host              $host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }
  }
}
```

</details>

<details>
<summary>SSL Passthrough</summary>

```
load_module /usr/lib64/nginx/modules/ngx_stream_module.so;
events {}
stream {
  upstream ccp {
    server 192.168.17.41:443;
    server 192.168.17.42:443;
    server 192.168.17.43:443;
  }
  server {
    listen 192.168.17.40:443;
    proxy_pass ccp;
  }
}
```

</details>

## Conjur

<details>
<summary>Configurations on Conjur servers to capture client IP address</summary>

```console
podman exec conjur evoke proxy add 192.168.0.50
```

</details>

<details>
<summary>SSL Termination</summary>

```
events {}
http {
  upstream conjur {
    server 192.168.17.51:443;
    server 192.168.17.52:443;
    server 192.168.17.53:443;
  }
  server {
    listen 192.168.17.50:443 ssl;
    server_name conjur.vx

    ssl on;
    ssl_certificate         /etc/nginx/ssl/conjur.pem;
    ssl_certificate_key     /etc/nginx/ssl/conjur.key;
    ssl_trusted_certificate /etc/nginx/ssl/cacert.pem;

    ssl_session_cache shared:SSL:20m;
    ssl_session_timeout 10m;

    ssl_prefer_server_ciphers on;
    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_ciphers               HIGH:!aNULL:!MD5;

    add_header Strict-Transport-Security "max-age=31536000";

    location / {
      proxy_pass https://conjur;
      proxy_set_header Host              $host;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }
  }
}
```

</details>

<details>
<summary>SSL Passthrough</summary>

```
load_module /usr/lib64/nginx/modules/ngx_stream_module.so;
events {}
stream {
  upstream conjur {
    server 192.168.17.51:443;
    server 192.168.17.52:443;
    server 192.168.17.53:443;
  }
  server {
    listen 192.168.17.50:443;
    proxy_pass conjur;
  }
}
```

</details>
