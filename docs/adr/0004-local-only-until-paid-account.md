# 第一版数据只存在本机，暂不做 iCloud 同步

原计划用 SwiftData + CloudKit 在 iPhone 和 iPad 之间同步会话，但 CloudKit 需要付费的 Apple Developer 账号，而我们目前没有。所以第一版的会话、图片和 API Key 都只存在本机。数据模型仍按 CloudKit 的约束来设计：所有属性可选或有默认值、不用唯一约束、关系都设为可选。这样有了账号以后，开启同步不需要做数据迁移。
