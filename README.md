# Lanboat Rules

适用于sing-box的路由规则数据，每天北京时间10:00自动构建并发布。

## 下载

| 文件 | 内容 |
| --- | --- |
| `geoip.dat` | 完整GeoIP，包含各国家、地区及其他IP分类 |
| `geoip-lite.dat` | 精简GeoIP，包含配置选定的分类 |
| `geolite2-asn.mmdb` | 完整ASN数据库 |
| `geosite.dat` | 完整域名分类数据 |
| `geosite-lite.dat` | 精简域名分类数据 |
| `geosite-lite.db` | 精简版旧格式域名数据库 |
| `lanboat-allinone-rules.tar.gz` | 全部分类的sing-box规则 |
| `lanboat-allinone-rules-lite.tar.gz` | 精简分类的sing-box规则 |
| `SHA256SUMS` | 发布文件的校验值 |

两个压缩包均包含可直接加载的SRS文件、分类索引及校验值。精简版减少分类数量，保留分类中的完整规则。

## 使用

下载并解压所需压缩包，然后在sing-box配置中引用规则文件。例如：

```json
{
  "route": {
    "rule_set": [
      {"type":"local","tag":"cn-domain","format":"binary","path":"/path/to/rules/srs/geosite/cn.srs"},
      {"type":"local","tag":"cn-ip","format":"binary","path":"/path/to/rules/srs/geoip/cn.srs"}
    ],
    "rules": [
      {"rule_set":"cn-domain","action":"route","outbound":"direct"},
      {"rule_set":"cn-ip","action":"route","outbound":"direct"}
    ],
    "final":"proxy"
  }
}
```

以上为路由片段，需要合并到现有配置，并配置相应的出站和DNS。分类用于匹配流量；直连、代理或拒绝由配置中的策略决定。

## 构建

构建环境为Linux x86_64，需安装Bash、`curl`、`jq`、GNU `tar/coreutils/findutils`和`gzip`。首次安装转换工具需要Go，后续可使用缓存。

```bash
bash scripts/setup-tools.sh
bash tests/test.sh --integration
bash build.sh
bash verify.sh dist
```

在`config.json`中可设置精简分类和需要生成规则的ASN。默认输出到`dist`，也可通过`--output`指定一个不存在的目录：

```bash
JOBS=4 bash build.sh --config config.json --output /path/to/new-dist
```

每次构建完成后验证产物；发布流程先上传至草稿，上传成功后公开。GitHub定时任务可能因排队延迟，仅在默认分支生效。

## 感谢

- [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip)
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)
- [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)
- [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)
- [MetaCubeX/meta-rules-converter](https://github.com/MetaCubeX/meta-rules-converter)
- [MetaCubeX/geo](https://github.com/MetaCubeX/geo)
- [snowie2000/geoview](https://github.com/snowie2000/geoview)
- [SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- [MaxMind](https://www.maxmind.com/)
