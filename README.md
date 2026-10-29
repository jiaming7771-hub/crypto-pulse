# Crypto Pulse Mini

macOS 桌面置顶 BTC / ETH / PENDLE 行情工具，使用 Binance 公开行情接口，不需要 API 密钥。

- BTC、ETH、PENDLE 实时报价与 24 小时涨跌幅，断线时回退为轮询。
- 可分别展开三张 K 线，支持 15 分钟、1 小时、4 小时和日线。
- K 线每 5 秒更新；超时请求自动清理，持续失败时重建会话，休眠唤醒时恢复连接。
- 支持拖动、缩放、跨桌面置顶与 Dock 启动。
- 图标采用用户选定的「玄青 × 古金」交织结形。

## 构建和启动

需要 macOS 13 或更高版本，以及 Xcode Command Line Tools。

```sh
./build.command
open "Crypto Pulse Mini.app"
```

生成的应用可拖入 Dock 固定。菜单栏行情图标提供「重新连接行情」入口。

## 验证

```sh
./test.command
```

回归测试覆盖：卡住的请求、三币种恢复、旧回调污染、正常刷新、连续失败、唤醒及手动重连、切换周期时的请求竞争。测试使用本地模拟，不请求线上行情。

## 图标

`assets/CryptoPulse-XuanqingGold.png` 为选定的原图，`assets/CryptoPulse-XuanqingGold.icns` 包含多种 Dock/Finder 显示尺寸。图片由内置 imagegen 生成，属于对传统文化意象的现代设计。构建脚本会把图标打包进应用。

PENDLE 报价及 K 线价格保留四位小数。
