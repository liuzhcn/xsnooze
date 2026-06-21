import Foundation

let privilegedHelperMachServiceName = "com.liuzhcn.XSnooze.Helper"

@objc(XSnoozePrivilegedHelperProtocol)
protocol PrivilegedHelperProtocol {
    func prepareHibernateAndSleep(_ reply: @escaping (Bool, String?) -> Void)
    func restoreHibernationModeIfNeeded(_ reply: @escaping (Bool, String?) -> Void)
    func status(_ reply: @escaping (Bool, String?) -> Void)
}

