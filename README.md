# iScreen Menu
**菜单栏里的 BenQ iScreenBar 灯控：亮度、色温、自动感光，以及与 Studio Display 的熄屏同步和亮度跟随。**

<img src="docs/images/menu.png" alt="iScreen Menu 菜单面板" width="345"> <img src="docs/images/menu-bar-icon.png" alt="菜单栏图标" width="36">

本仓库 fork 自 [rogerbush007-a11y/iScreenBar-StudioDisplay-Sync](https://github.com/rogerbush007-a11y/iScreenBar-StudioDisplay-Sync)，只保留与灯光相关的功能，并重做了菜单界面。非官方独立项目，与 BenQ、Apple 无隶属关系，以 MIT 许可证发布。

## 本 fork 的改动

- **原生菜单界面**：弹出气泡改为系统菜单；顶部为灯光面板，下方为原生子菜单与“退出”（⌘Q），自动适配浅色/深色模式。
- **只保留灯光功能**：移除内屏开关与旋转、旋转预设、Studio Display 黑色遮罩、防止休眠、MacBook 与 Studio Display 双屏亮度锁定、锁屏时立即熄屏。App 不再请求管理员权限。
- **菜单栏图标**：单色圆环，周围 8 条光芒按亮度依次点亮；同步异常时右下角显示小圆点。
- **Studio Display 识别**：除型号 0xAE46 外，也识别 0xAE3A 及名称为 “Studio Display” 的屏幕；此前部分 Studio Display 无法识别，熄屏同步与亮度跟随不会生效。
- **灯关闭时也可调节**：拖动亮度/色温或切换自动感光、应用灯光预设时先开灯再写入（灯关闭时固件会忽略这些指令）。
- **稳定性**：菜单展开时同步与状态回读不中断；从菜单退出后不再被 LaunchAgent 自动拉起，仅在异常退出时重启；声明最低系统版本 macOS 14。

## 界面与功能

详见 [界面使用指南](docs/UI-GUIDE.zh-CN.md) · [完整功能清单](docs/FEATURES.zh-CN.md)。

| 区域 | 功能 |
| --- | --- |
| 顶部 | 连接状态、当前亮度与色温；右侧圆形按钮开关灯 |
| 滑块 | 亮度（白色填充）与 2700–6500K 色温（暖到冷渐变）；自动感光开启时亮度滑块置灰，自动色温开启时色温滑块置灰 |
| 开关 | 自动感光、自动色温、入座检测、视频模式、亮度跟随、熄屏同步 |
| 子菜单 | 入座检测设置（离席时间、灵敏度）、环境光标定、灯光预设与模式中心 |

App 不占 Dock 位置，悬停图标显示亮度和色温。

## 安装

已测试：Apple Silicon Mac、macOS 26–27、Studio Display、BenQ iScreenBar（USB VID 0x04A5 / PID 0x2501）。其他系统和设备尚未全面验证；需要 macOS 14 或更高版本。

先安装 Xcode Command Line Tools，然后运行：

```bash
xcode-select --install
git clone https://github.com/alexcding/iScreenBar-StudioDisplay-Sync.git
cd iScreenBar-StudioDisplay-Sync
./scripts/install.sh
```

脚本本机编译、临时签名，安装到 `~/Applications/iScreen Menu.app`，创建用户级 LaunchAgent，登录后自动运行。安装和使用都不需要管理员密码。

日常灯控直接通过 USB HID 执行，不依赖官方 App。建议避免两个软件同时自动写入灯光设置。相机自动视频模式和灯体硬件记忆尚未完全对齐，不宣称完整替代官方所有功能。

## 使用规则

- 亮度跟随与灯体自动感光互斥，关闭跟随后保留当前亮度。
- 熄屏同步开启时，Studio Display 熄屏即关灯；希望熄屏后保持灯亮，请关闭“熄屏同步”。
- 环境光采用近 10 秒中位数。明亮关灯约 30 秒，达到昏暗开灯点约 30 秒；环境关灯后的渐进回开约 45 秒。带回差与持续时间判断，不是越过数值就立即切换。环境光规则关灯期间，调节滑块不会重新开灯。

## 验证与限制

```bash
./scripts/check.sh
tail -f ~/Library/Logs/iScreenBarStudioSync.log
launchctl print gui/$(id -u)/local.qiu.iScreenBarStudioSync
```

亮度读取使用 macOS 私有 DisplayServices 接口，系统升级后需要复测。USB 报文针对特定灯型，其他 ScreenBar 型号不保证兼容。构建通过、系统状态回读不代表面板确实发光。

## 卸载与开发

```bash
./scripts/uninstall.sh
# 仅构建，不安装：
./scripts/build.sh
```

卸载将 App 和 LaunchAgent 移至废纸篓，保留日志。构建产物位于 `build/iScreen Menu.app`。目前为本机临时签名，无 Developer ID 公证或自动更新。

源码无网络请求、分析或云端依赖。参见 [安全说明](SECURITY.md)、[商标声明](NOTICE.md)、[MIT 许可证](LICENSE)。
