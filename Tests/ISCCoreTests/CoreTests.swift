import Foundation
import Testing
@testable import ISCCore

// 这些测试锁住的是**接口形状**：内核发什么字段名、缺字段时怎么表现。
// 它们不进内核，因此可以在毫秒级跑完；真正的端到端在
// KernelIntegrationTests 里。

@Test func jsonRoundTrip() throws {
    let value = try JSONValue.parse(#"{"a":[1,2,{"b":null}],"c":"x"}"#)
    #expect(value["c"].string == "x")
    #expect(value["a"].array.count == 3)
    #expect(value["a"].array[2]["b"] == .null)
    #expect(try JSONValue.parse(value.text()) == value)
}

@Test func errorUsesMachineCode() throws {
    let envelope = try JSONValue.parse(#"{"ok":false,"code":"not_found","status":404,"error":"nope"}"#)
    do {
        _ = try KernelReply(envelope)
        Issue.record("a failed envelope must throw")
    } catch let error as KernelError {
        #expect(error.code == "not_found")
        #expect(error.status == 404)
        #expect(error.message == "nope")
    }
}

@Test func identifiersCannotInjectPathOrQuery() {
    #expect(KernelClient.pathComponent("a/b?x=1") == "a%2Fb%3Fx%3D1")
    #expect(KernelClient.pathComponent("plain-id_1") == "plain-id_1")
}

// MARK: - 解码

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try KernelClient.makeDecoder().decode(T.self, from: Data(json.utf8))
}

@Test func presetDecodingMapsSnakeCaseAndOptionals() throws {
    let json = """
    {"items":[
      {"id":"node-auto","version":"1","title":"Node.js","kind":"node",
       "min_version":"18.0.0","default_port":3000,"docker_only":false,
       "detector_files":["package.json"],"detector_suffixes":[".js"],"note":"说明"},
      {"id":"static-html","version":"1","title":"静态站点","kind":"","default_port":8080}
    ]}
    """
    let catalog = try decode(PresetCatalog.self, json)
    #expect(catalog.items.count == 2)
    let node = catalog.items[0]
    #expect(node.minVersion == "18.0.0")
    #expect(node.detectorFiles == ["package.json"])
    #expect(node.isStatic == false)
    // 缺字段的条目必须能解出来，而不是整份目录失败。
    #expect(catalog.items[1].isStatic)
    #expect(catalog.items[1].minVersion == nil)
}

@Test func appDecodingCarriesDomainAndRuntimeState() throws {
    let json = """
    {"id":"app1","name":"站点","preset_id":"static-html","kind":"",
     "source_path":"/tmp/site","local_port":41234,"state":"running","health":"healthy",
     "auto_start":true,"max_restarts":3,"restart_count":0,
     "domains":[{"name":"a.example.com","route_ready":true,"cert_needs_renew":false,
                 "cert_expires_at":"2027-01-02T03:04:05Z"}],
     "runtime":{"kind":"","version":"","source":"none"},
     "created_at":"2026-10-04T14:50:00.123Z","updated_at":"2026-10-04T14:51:00Z"}
    """
    let app = try decode(AppRecord.self, json)
    #expect(app.state == "running")
    #expect(app.isRunning)
    #expect(app.isBusy == false)
    #expect(app.domainNames == ["a.example.com"])
    let domain = try #require(app.domains?.first)
    #expect(domain.routeReady == true)
    #expect(domain.certExpiresAt != nil)
    // 两种时间戳形状（带/不带小数秒）都要能解。
    #expect(app.createdAt != nil)
    #expect(app.updatedAt != nil)
}

@Test func appDecodingToleratesAbsentCollections() throws {
    // 没有域名、也没有运行时的站点是最常见的形态（还没绑定、是静态站点）。
    let json = """
    {"id":"a","name":"n","preset_id":"static-html","kind":"","source_path":"/tmp",
     "local_port":8080,"state":"draft","health":"unknown"}
    """
    let app = try decode(AppRecord.self, json)
    #expect(app.domains == nil)
    #expect(app.domainNames.isEmpty)
    #expect(app.runtime == nil)
    #expect(app.lastError == nil)
}

@Test func metricsDecodingIncludesZeroesRatherThanFailing() throws {
    let json = """
    {"host":{"cpu_percent":0,"memory_used_bytes":0,"memory_total_bytes":0,
             "net_rx_bytes_per_sec":0,"net_tx_bytes_per_sec":0,"backend":"unsupported"},
     "apps":[],"history":[]}
    """
    let snapshot = try decode(MetricsSnapshot.self, json)
    #expect(snapshot.host.isSupported == false)
    #expect(snapshot.host.memoryFraction == 0)
    // 除以内存总量时不能崩：平台不支持时它是 0。
    #expect(snapshot.host.memoryFraction.isFinite)
}

@Test func appMetricsDistinguishesHostedFromOwnProcess() throws {
    let json = #"{"app_id":"a","pid":0,"cpu_percent":0,"memory_bytes":0,"uptime_seconds":42}"#
    let sample = try decode(AppMetrics.self, json)
    #expect(sample.hasOwnProcess == false, "静态站点由内核托管，没有独立进程")
    #expect(sample.uptimeSeconds == 42)
}

@Test func advisoryDecodingKeepsTheActionBodyAsRawJSON() throws {
    let json = """
    {"items":[{"id":"runtime_missing:a:node","severity":"blocking","title":"缺少运行时",
      "detail":"细节","action":{"label":"现在准备","method":"POST",
      "path":"/v1/runtimes/provision","body":{"kinds":["node"]}}}]}
    """
    let list = try decode(AdvisoryList.self, json)
    let advisory = try #require(list.items.first)
    #expect(advisory.isBlocking)
    let action = try #require(advisory.action)
    #expect(action.method == "POST")
    #expect(action.body?["kinds"].array.first?.string == "node")
}

@Test func jobDecodingSurfacesTheFailureReason() throws {
    let json = """
    {"id":"j1","kind":"app.deploy","status":"failed",
     "error":{"code":"deploy_failed","detail":"npm install failed"},
     "created_at":"2026-10-04T14:50:00Z","finished_at":"2026-10-04T14:50:05Z"}
    """
    let job = try decode(JobInfo.self, json)
    #expect(job.isFinished)
    #expect(job.failedMessage == "npm install failed")
}

// MARK: - 编码

/// 把一个 Encodable 编成 JSON 对象再断言键值。
///
/// 不靠字符串包含来断言：JSONEncoder 在 Apple 平台上默认把 `/` 转义成
/// `\/`（合法 JSON，解码后仍是 `/`），逐字比较会得出错误结论。
private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try KernelClient.makeEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func createRequestOmitsAbsentOptionals() throws {
    var request = AppCreateRequest(name: "站点", presetId: "static-html", sourcePath: "/tmp/site")
    request.domains = ["a.example.com"]
    let object = try encodedObject(request)

    #expect(object["preset_id"] as? String == "static-html")
    #expect(object["source_path"] as? String == "/tmp/site")
    #expect(object["domains"] as? [String] == ["a.example.com"])
    // 没设过的字段不该出现在请求里：契约把它们当"不改动"。
    #expect(object["port"] == nil)
    #expect(object["custom_executable"] == nil)
    #expect(object["max_restarts"] == nil)
}

@Test func settingsPatchOnlyCarriesWhatWasSet() throws {
    var patch = KernelSettings()
    patch.lang = "zh-CN"
    patch.proxyEnabled = true
    let object = try encodedObject(patch)
    #expect(object["lang"] as? String == "zh-CN")
    #expect(object["proxy_enabled"] as? Bool == true)
    #expect(object["acme_email"] == nil, "没设过的字段必须留空，否则会被当成清空")
    #expect(object["proxy_port"] == nil)
}

@Test func versionGuardNamesTheVersionItNeeds() {
    #expect(KernelClient.requiredAPIVersion == "v2")
}

// MARK: - 解码：内核真实发过来的形状

// 这一组是补出来的。此前 `DdnsTaskInfo.ipv4` 被写成了 `String?`，而内核发的
// 是**对象** —— 解码必然抛错，而调用方用 `attempt` 把错误吞掉了，于是首页的
// "动态解析"永远显示"还没有任务"，即使内核里明明有。
//
// 教训是："吞掉解码错误"这个便利是有代价的：契约与模型对不上时不会有人
// 发现。因此下面用的是内核真实会发的形状。
@Test func ddnsTaskDecodingHandlesObjectSources() throws {
    let json = """
    {"items":[{
      "id":"t1","credential_id":"c1","label":"家里的 IPv6","enabled":true,
      "ipv4":{"enable":false,"get_type":"netInterface","value":"","domains":[]},
      "ipv6":{"enable":true,"get_type":"netInterface","value":"","domains":["home.example.com","www.example.com"],
              "selector":"@2"},
      "ttl":"600","http_interface":"en0",
      "last_run_at":"2026-10-04T07:49:09Z","last_status":"success","last_message":"",
      "last_ipv4":"1.2.3.4","last_ipv6":"2001:db8::1",
      "created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-04T07:49:09Z"
    }]}
    """
    let list = try decode(DdnsTaskList.self, json)
    let task = try #require(list.items.first)
    #expect(task.label == "家里的 IPv6")
    #expect(task.updatesIPv6)
    #expect(task.updatesIPv4 == false)
    #expect(task.domains == ["home.example.com", "www.example.com"])
    #expect(task.ipv6?.selector == "@2")
    #expect(task.ttl == "600")
    #expect(task.lastIpv6 == "2001:db8::1")
    #expect(task.lastRunAt != nil)
}

@Test func ddnsTaskDecodingToleratesMissingOptionalSources() throws {
    // 只要必填字段在，可选的来源缺失不该让整份列表解不出来。
    let json = """
    {"items":[{"id":"t1","credential_id":"c1","label":"x","enabled":false,
               "created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z"}]}
    """
    let list = try decode(DdnsTaskList.self, json)
    let task = try #require(list.items.first)
    #expect(task.ipv4 == nil && task.ipv6 == nil)
    #expect(task.domains.isEmpty)
    #expect(task.enabled == false)
}

@Test func providerDecodingCarriesCapabilitiesAndFields() throws {
    let json = """
    {"items":[{"name":"cloudflare","display_name":"Cloudflare","tier":1,
      "capabilities":{"available":true,"verify":true,"dynamic":true,"zone_list":true,
                      "record_list":true,"record_create":true,"record_update":true,
                      "record_delete":true,"dns01":true},
      "credential_fields":[
        {"key":"token","label":"API Token","secret":true,"required":true,"help":"需要 Zone:DNS:Edit 权限"},
        {"key":"account","label":"Account","secret":false,"required":false}
      ]}]}
    """
    let list = try decode(ProviderList.self, json)
    let provider = try #require(list.items.first)
    #expect(provider.capabilities.dns01)
    #expect(provider.capabilities.canManageRecords)
    #expect(provider.credentialFields.count == 2)
    #expect(provider.credentialFields[0].secret)
    #expect(provider.credentialFields[1].required == false)
    #expect(provider.credentialFields[0].help == "需要 Zone:DNS:Edit 权限")
}

@Test func credentialDecodingIncludesVerificationState() throws {
    let json = """
    {"items":[{"id":"c1","provider":"cloudflare","label":"我的CF",
               "capabilities":{"available":true,"verify":true,"dynamic":true,"zone_list":true,
                               "record_list":true,"record_create":true,"record_update":true,
                               "record_delete":true,"dns01":true},
               "last_verified_at":"2026-10-04T07:00:00Z","last_verify_ok":false,
               "last_verify_error":"invalid token"}]}
    """
    let list = try decode(CredentialList.self, json)
    let credential = try #require(list.items.first)
    #expect(credential.verifyState == "failed")
    #expect(credential.capabilities?.dns01 == true)
    #expect(credential.lastVerifyError == "invalid token")
}

@Test func credentialWithoutCapabilitiesIsStillUsable() throws {
    // 老内核可能不发 capabilities；界面应当降级而不是整份列表解不出来。
    let json = #"{"items":[{"id":"c1","provider":"x","label":"y"}]}"#
    let list = try decode(CredentialList.self, json)
    #expect(list.items.first?.capabilities == nil)
    #expect(list.items.first?.verifyState == "unverified")
}

// 行动作的两种形态。
@Test func advisoryActionDecodesBothKinds() throws {
    let navigation = """
    {"items":[{"id":"first_run_setup","severity":"info","title":"先添加凭据",
      "action":{"label":"去添加","navigation":"credentials"}}]}
    """
    let list = try decode(AdvisoryList.self, navigation)
    let action = try #require(list.items.first?.action)
    #expect(action.isNavigation)
    #expect(action.navigation == "credentials")
    #expect(action.method == nil)

    let call = """
    {"items":[{"id":"proxy_disabled","severity":"blocking","title":"反代没开",
      "action":{"label":"启用","method":"PATCH","path":"/v1/settings",
                "body":{"proxy_enabled":true}}}]}
    """
    let callList = try decode(AdvisoryList.self, call)
    let callAction = try #require(callList.items.first?.action)
    #expect(callAction.isNavigation == false)
    #expect(callAction.method == "PATCH")
    #expect(callAction.body?["proxy_enabled"] == .bool(true))
}

@Test func auditEntryDecodingCarriesResultAndDetail() throws {
    let json = """
    {"items":[{"id":"e1","ts":"2026-10-04T07:49:09Z","action":"app.deploy",
               "target":"我的站点","result":"failure","detail":"npm install failed",
               "request_id":"r1","remote":"local"}],
     "next_cursor":"c2"}
    """
    let list = try decode(AuditList.self, json)
    let entry = try #require(list.items.first)
    #expect(entry.action == "app.deploy")
    #expect(entry.failed)
    #expect(entry.detail == "npm install failed")
    #expect(list.nextCursor == "c2")
}

@Test func jobListDecodingDistinguishesFinishedFromRunning() throws {
    // 这条区分决定界面显示"取消"还是"完成"，也决定首页要不要显示进度条。
    let json = """
    {"items":[
      {"id":"j1","kind":"app.deploy","status":"running","progress":0.4,"message":"正在构建",
       "created_at":"2026-10-04T07:00:00Z"},
      {"id":"j2","kind":"runtime.provision","status":"succeeded",
       "created_at":"2026-10-04T06:00:00Z","finished_at":"2026-10-04T06:05:00Z"}
    ]}
    """
    let list = try decode(JobList.self, json)
    #expect(list.items.count == 2)
    #expect(list.items[0].isFinished == false)
    #expect(list.items[0].progress == 0.4)
    #expect(list.items[1].isFinished)
    #expect(list.items[1].failedMessage == nil)
}

@Test func providerConsoleURLIsOptionalAndHTTPSOnly() throws {
    // 内核没登记凭据页面时不能因为缺字段就整份目录解不出来 ——
    // 那会让"添加凭据"整页空掉（ProviderCapabilities 上犯过同样的错）。
    let list = try decode(ProviderList.self, """
    {"items":[
      {"name":"cloudflare","display_name":"Cloudflare","tier":1,
       "capabilities":{"available":true,"verify":true},
       "credential_fields":[{"key":"token","label":"API 令牌","secret":true,"required":true}],
       "console_url":"https://dash.cloudflare.com/profile/api-tokens"},
      {"name":"mystery","display_name":"Mystery","tier":2,
       "capabilities":{"available":true},
       "credential_fields":[]}
    ]}
    """)
    #expect(list.items.count == 2)

    let cloudflare = list.items[0]
    #expect(cloudflare.consoleUrl == "https://dash.cloudflare.com/profile/api-tokens")
    #expect(cloudflare.credentialPageURL?.host() == "dash.cloudflare.com")

    // 没有登记的服务商：没有地址，界面就不该给"去配置"按钮。
    #expect(list.items[1].consoleUrl == nil)
    #expect(list.items[1].credentialPageURL == nil)
}

@Test func providerConsoleURLRejectsNonHTTPS() throws {
    // 这个地址会被直接交给系统浏览器打开，而它来自内核（外部数据）。
    // http 的凭据页面本就不该存在；真出现了也不该由我们替用户打开。
    func provider(_ url: String) throws -> Provider {
        try decode(Provider.self, """
        {"name":"x","display_name":"X","tier":1,"capabilities":{},
         "credential_fields":[],"console_url":"\(url)"}
        """)
    }
    #expect(try provider("http://example.com/keys").credentialPageURL == nil)
    #expect(try provider("javascript:alert(1)").credentialPageURL == nil)
    #expect(try provider("file:///etc/passwd").credentialPageURL == nil)
    #expect(try provider("not a url").credentialPageURL == nil)
    #expect(try provider("https://example.com/keys").credentialPageURL != nil)
}
