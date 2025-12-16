function FindProxyForURL(url, host) {
    // 如果是本地地址或内网地址，直连
    if (isPlainHostName(host) || 
        shExpMatch(host, "*.local") ||
        isInNet(host, "10.0.0.0", "255.0.0.0") ||
        isInNet(host, "172.16.0.0", "255.240.0.0") ||
        isInNet(host, "192.168.0.0", "255.255.0.0") ||
        isInNet(host, "127.0.0.1", "255.255.255.255")) {
        return "DIRECT";
    }

    // 其他所有请求通过代理服务器
    return "PROXY 192.168.23.21:5688; DIRECT";
}