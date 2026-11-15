import Foundation

/// 读写消息里保存的组件状态（`Message.componentStateJSON`）。状态的内容由各组件自己决定，这里只按组件键合并。
public enum ComponentStateStore {
    /// 更新一个组件的状态。`state` 为 nil 或 NSNull 时删除这个组件的状态（复位）。
    public static func updating(_ json: String, key: String, state: Any?) -> String {
        var all = decode(json)
        if let state, !(state is NSNull) {
            all[key] = state
        } else {
            all.removeValue(forKey: key)
        }
        guard !all.isEmpty,
              JSONSerialization.isValidJSONObject(all),
              let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 解析保存的状态。内容为空或格式不对时返回空字典。
    public static func decode(_ json: String) -> [String: Any] {
        guard !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }
}
