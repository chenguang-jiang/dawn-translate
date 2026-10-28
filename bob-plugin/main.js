// Bob translate plugin: DawnTranslate's Chinese ⇄ English prompt over the user's own
// Chat Completions service. Bob runs this in JavaScriptCore with $http/$option/$log.

var core = require('./lib/core.js');

var REQUEST_TIMEOUT_SECONDS = 90;

function supportLanguages() {
    return ['auto', 'zh-Hans', 'zh-Hant', 'en'];
}

function translate(query, completion) {
    if (query.to === 'zh-Hant') {
        completion({ error: core.failure('unsupportLanguage', '目前只支持译成简体中文或英文。') });
        return;
    }
    var options = { baseURL: $option.baseURL, model: $option.model, apiKey: $option.apiKey };
    var target = core.endpoint(options.baseURL);
    if (target.error) {
        completion({ error: target.error });
        return;
    }
    var invalid = core.validate(query.text, options);
    if (invalid) {
        completion({ error: invalid });
        return;
    }
    var dir = core.direction(query);
    var header = { 'Content-Type': 'application/json' };
    var apiKey = String(options.apiKey || '').trim();
    if (apiKey) { header.Authorization = 'Bearer ' + apiKey; }

    $http.request({
        method: 'POST',
        url: target.url,
        header: header,
        body: core.payload(options.model, core.systemPrompt(dir), query.text, target.host),
        timeout: REQUEST_TIMEOUT_SECONDS,
        handler: function (resp) {
            completion(handleResponse(resp, query, dir));
        }
    });
}

function handleResponse(resp, query, dir) {
    if (resp.error) {
        $log.error('request failed|domain=' + resp.error.domain + '|code=' + resp.error.code);
        return { error: core.failure('network', '网络请求失败：' + (resp.error.localizedDescription || '请检查网络和服务地址。')) };
    }
    var status = resp.response ? resp.response.statusCode : 0;
    if (status < 200 || status >= 300) {
        $log.error('http status|status=' + status);
        return { error: core.statusFailure(status) };
    }
    var content = core.replyContent(resp.data);
    if (!content) {
        return { error: core.failure('api', '服务返回了空内容或不兼容的格式；请使用 Chat Completions 兼容接口。') };
    }
    var languages = core.resultLanguages(query, dir);
    return {
        result: {
            from: languages.from,
            to: languages.to,
            toParagraphs: core.paragraphs(content)
        }
    };
}
