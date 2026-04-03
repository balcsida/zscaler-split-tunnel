import Foundation

let helper = HelperTool()
let listener = NSXPCListener(machServiceName: AppConstants.machServiceName)
listener.delegate = helper
listener.resume()
RunLoop.main.run()
