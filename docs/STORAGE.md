# Alaud 0.2 存储与按需恢复

## 数据流

Watch 录音暂存 → iPhone 完整落盘并校验 → Watch 清理 → iPhone 自动上传 iCloud Drive → 上传确认后释放手机原音。Mac 录音也先落盘，再上传同一云端库。

| 内容 | 云端 | 本地 |
| --- | --- | --- |
| 原音 | `iCloud.com.gaoyiming.alaud` 的 `Documents/Library/Audio` | 录音、待上传、播放或转写期间暂存；安全确认后释放 |
| 标题、备注、转写、待办 | 同容器 `Library/Meetings` | 保留轻量索引和待同步编辑 |
| 语音模型 | Apple 语言资源 | 按设备准备，不属于录音云缓存 |

原音为 16 kHz、单声道、16 bit PCM CAF，约每 60 秒一片，约 115 MB/小时。云端占用户自己的 iCloud 配额，没有开发者录音服务器。开发包的云端文件使用 iCloud Drive，不使用 CloudKit Development / Production 数据库。

## 何时清理

Watch 只接受包含最终片数与逐片 SHA-256 的完整存储回执。手机检查每个文件、清单和结束状态并同步到磁盘后才能发回执；若手机已经把原音安全迁入云端，也必须先验证当前账号和完整云端回执。手表核对后原子移入 `.cleanup` 再移除，不进入最近删除。旧版片段回执、传输完成回调、缺片、孤立原音或未结束的录音均不足以触发删除。

手机 / Mac 上传不可变原音文件，等待 Apple 的 `ubiquitousItemIsUploaded` 明确为真，随后保存逐片摘要与字节数、完整会议快照、可发现的 head 标记；最后重新验证账号和全场回执，才释放没有使用租约的本地原音。iCloud Drive 提供的本地镜像也通过 `evictUbiquitousItem` 释放，不调用会删除云端文件的 `removeItem`。失败时保留原件。

本轮不提供云端永久删除。释放缓存不等于删除会议；也不能把云同步当成防止用户误删 iCloud 文件的独立备份。

## 多端同步和恢复

会议快照与 head 标记只追加，每个快照记录父版本；并发修改形成分支，再按共同祖先合并标题、备注、转写和待办。冲突文字保留在备注，不静默覆盖。音频内容按摘要命名，元数据列表不会批量下载所有原音。元数据历史会随编辑增长，尚未实现云端历史压缩。

播放、转写、分享先取得音频租约：本地缺少时按需下载，校验 SHA-256 后才使用；最后一个使用者释放后清理。导出分享另有临时文件，分享结束删除；异常遗留导出在一小时后清理。设置显示并可释放已获云端完整确认的音频缓存。

应用激活、本地编辑、Watch 接收及录音结束时触发同步；Mac 前台每 30 秒检查。iPhone 会申请后台同步，但系统可能延迟或中止执行，下次激活继续，不能保证 App 退出后立刻上传。换 iCloud 账号时停止原库同步和自动清理，避免把旧账号内容上传到新账号；本版本不提供账号迁移向导。

## 空间与离线边界

并非零本地占用：录音原件在上传前必须存在，回听和转写要下载，文字索引和模型也长期占空间。已释放缓存的会议离线时无法回听。iCloud 未登录、Drive 未开启、配额不足或网络失败时，待上传原音会继续占本地空间。跨设备首次同步和大量历史文件可需要较长时间。

平台依据：[确认上传](https://developer.apple.com/documentation/foundation/urlresourcevalues/ubiquitousitemisuploaded)、[移入 iCloud](https://developer.apple.com/documentation/foundation/filemanager/setubiquitous(_:itemat:destinationurl:))、[只释放本地 iCloud 副本](https://developer.apple.com/documentation/foundation/filemanager/evictubiquitousitem(at:))。
