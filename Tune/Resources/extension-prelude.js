/*
 * Tune extension prelude.
 *
 * Mornye extensions are plain JavaScript. This file supplies the host surface
 * they expect (http/fetch, file, storage, utils, matching, timers) on top of
 * the small native bridge injected by JSContextRuntime.swift.
 */
(function () {
    "use strict";

    var info = {};
    try { info = JSON.parse(__host_info()); } catch (e) { info = {}; }

    var host = {
        request: __host_request,
        file: __host_file,
        download: __host_download,
        downloadSegments: __host_download_segments,
        storage: __host_storage,
        log: __host_log,
        timerSet: __host_timer_set,
        timerClear: __host_timer_clear,
        cancelled: __host_cancelled,
        sleep: __host_sleep,
        compareStrings: __host_compare_strings,
        compareDuration: __host_compare_duration,
        normalize: __host_normalize,
        hash: __host_hash,
        crypt: __host_crypt,
        generateKey: __host_generate_key,
        blockTransform: __host_block_transform,
        ffmpeg: __host_ffmpeg,
        utf8Encode: __host_utf8_encode,
        utf8Decode: __host_utf8_decode,
        base64Encode: __host_base64_encode,
        base64Decode: __host_base64_decode
    };

    function text(value) {
        return value === undefined || value === null ? "" : String(value);
    }

    function jsonParse(value, fallback) {
        try { return JSON.parse(value); } catch (e) { return fallback; }
    }

    // MARK: - URL / URLSearchParams

    function encodeQuery(value) {
        return encodeURIComponent(text(value)).replace(/%20/g, "+");
    }

    function decodeQuery(value) {
        try { return decodeURIComponent(String(value).replace(/\+/g, " ")); } catch (e) { return String(value); }
    }

    function URLSearchParams(init) {
        this._list = [];
        if (init === undefined || init === null) return;
        if (typeof init === "string") {
            var raw = init.replace(/^\?/, "");
            if (!raw) return;
            raw.split("&").forEach(function (pair) {
                if (!pair) return;
                var index = pair.indexOf("=");
                var key = index < 0 ? pair : pair.slice(0, index);
                var value = index < 0 ? "" : pair.slice(index + 1);
                this._list.push([decodeQuery(key), decodeQuery(value)]);
            }, this);
        } else if (typeof init === "object") {
            Object.keys(init).forEach(function (key) {
                this._list.push([String(key), text(init[key])]);
            }, this);
        }
    }
    URLSearchParams.prototype.append = function (key, value) { this._list.push([text(key), text(value)]); };
    URLSearchParams.prototype.delete = function (key) { this._list = this._list.filter(function (pair) { return pair[0] !== text(key); }); };
    URLSearchParams.prototype.get = function (key) {
        var found = this._list.filter(function (pair) { return pair[0] === text(key); });
        return found.length ? found[0][1] : null;
    };
    URLSearchParams.prototype.getAll = function (key) {
        return this._list.filter(function (pair) { return pair[0] === text(key); }).map(function (pair) { return pair[1]; });
    };
    URLSearchParams.prototype.has = function (key) { return this.get(key) !== null; };
    URLSearchParams.prototype.set = function (key, value) {
        var replaced = false;
        var result = [];
        this._list.forEach(function (pair) {
            if (pair[0] === text(key)) {
                if (!replaced) { result.push([text(key), text(value)]); replaced = true; }
            } else {
                result.push(pair);
            }
        });
        if (!replaced) result.push([text(key), text(value)]);
        this._list = result;
    };
    URLSearchParams.prototype.toString = function () {
        return this._list.map(function (pair) { return encodeQuery(pair[0]) + "=" + encodeQuery(pair[1]); }).join("&");
    };
    URLSearchParams.prototype.forEach = function (callback, thisArg) {
        this._list.forEach(function (pair) { callback.call(thisArg, pair[1], pair[0], this); }, this);
    };

    function parseURL(input, base) {
        var raw = text(input).trim();
        if (!raw) throw new TypeError("Invalid URL");
        if (base && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(raw)) {
            var b = parseURL(base);
            if (raw.charAt(0) === "/") raw = b.protocol + "//" + b.host + raw;
            else if (raw.charAt(0) === "?") raw = b.protocol + "//" + b.host + b.pathname + raw;
            else if (raw.charAt(0) === "#") raw = b.protocol + "//" + b.host + b.pathname + b.search + raw;
            else raw = b.protocol + "//" + b.host + b.pathname.replace(/[^/]*$/, "") + raw;
        }
        var match = /^([a-zA-Z][a-zA-Z0-9+.-]*:)(?:\/\/([^/?#]*))?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(raw);
        if (!match) throw new TypeError("Invalid URL");
        var protocol = match[1].toLowerCase();
        var authority = match[2] || "";
        var credentials = authority.indexOf("@") >= 0 ? authority.slice(0, authority.lastIndexOf("@")) : "";
        var hostAndPort = authority.indexOf("@") >= 0 ? authority.slice(authority.lastIndexOf("@") + 1) : authority;
        var portMatch = /:(\d+)$/.exec(hostAndPort);
        var port = portMatch ? portMatch[1] : "";
        var hostname = hostAndPort.replace(/:\d+$/, "").toLowerCase();
        var pathname = match[3] || "/";
        if (pathname.charAt(0) !== "/" && (protocol === "http:" || protocol === "https:")) pathname = "/" + pathname;
        var search = match[4] || "";
        var hash = match[5] || "";
        return {
            protocol: protocol,
            host: hostname + (port ? ":" + port : ""),
            hostname: hostname,
            port: port,
            pathname: pathname,
            search: search,
            hash: hash,
            username: credentials,
            origin: protocol === "http:" || protocol === "https:" ? protocol + "//" + hostname + (port ? ":" + port : "") : "null",
            href: protocol + (authority ? "//" + authority : "") + pathname + search + hash,
            searchParams: new URLSearchParams(search),
            toString: function () { return this.href; },
            toJSON: function () { return this.href; }
        };
    }

    function URL(input, base) {
        if (!new.target) throw new TypeError("URL requires new");
        var parsed = parseURL(input, base);
        Object.assign(this, parsed);
        var self = this;
        this.toString = function () { return self.href; };
        this.toJSON = function () { return self.href; };
    }

    globalThis.URL = URL;
    globalThis.URLSearchParams = URLSearchParams;

    // MARK: - HTTP

    function makeResponse(payload, url) {
        var body = payload.body === undefined || payload.body === null ? "" : String(payload.body);
        var status = Number(payload.status !== undefined ? payload.status : payload.statusCode) || 0;
        var headers = payload.headers || {};
        var response = {
            ok: status >= 200 && status < 300,
            status: status,
            statusCode: status,
            statusText: payload.statusText || "",
            headers: headers,
            url: payload.url || text(url),
            body: body,
            error: payload.error,
            text: function () { return body; },
            json: function () { return JSON.parse(body); },
            arrayBuffer: function () {
                var binary = atob(payload.base64 || "");
                var bytes = new Uint8Array(binary.length);
                for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i) & 255;
                return bytes;
            }
        };
        return response;
    }

    function requestRaw(method, url, body, headers, timeout) {
        var raw;
        try {
            raw = host.request(
                text(method || "GET").toUpperCase(),
                text(url),
                JSON.stringify(headers || {}),
                body === undefined || body === null ? "" : String(body),
                Number(timeout) > 0 ? Number(timeout) : 30
            );
        } catch (e) {
            return { error: String(e && e.message || e), status: 0 };
        }
        return jsonParse(raw, { error: "invalid host response", status: 0 });
    }

    function httpRequest(method, url, body, headers, timeout) {
        return makeResponse(requestRaw(method, url, body, headers, timeout), url);
    }

    globalThis.http = {
        get: function (url, headers) { return httpRequest("GET", url, null, headers, 30); },
        post: function (url, body, headers) { return httpRequest("POST", url, body, headers, 30); },
        put: function (url, body, headers) { return httpRequest("PUT", url, body, headers, 30); },
        patch: function (url, body, headers) { return httpRequest("PATCH", url, body, headers, 30); },
        delete: function (url, headers) { return httpRequest("DELETE", url, null, headers, 30); },
        request: function (url, options) {
            options = options || {};
            return httpRequest(options.method || "GET", url, options.body, options.headers, options.timeout || 30);
        },
        clearCookies: function () { return true; }
    };

    globalThis.fetch = function (url, options) {
        options = options || {};
        if (options.signal && options.signal.aborted) {
            return makeResponse({ error: "aborted", status: 0 }, url);
        }
        var body = options.body;
        if (body && typeof body === "object" && !(body instanceof Uint8Array) && !(body instanceof ArrayBuffer)) {
            body = JSON.stringify(body);
        }
        return makeResponse(requestRaw(options.method || "GET", url, body, options.headers, options.timeout), url);
    };

    // MARK: - File

    function fileCall(method, path, value, options) {
        var raw = host.file(String(method), JSON.stringify({
            path: text(path), value: value === undefined ? null : value, options: options || {}
        }));
        return jsonParse(raw, { success: false, error: "invalid host response" });
    }

    function bytesToBase64(value) {
        if (value instanceof ArrayBuffer) value = new Uint8Array(value);
        var binary = "";
        for (var i = 0; i < value.length; i++) binary += String.fromCharCode(value[i] & 255);
        return btoa(binary);
    }

    globalThis.file = {
        download: function (url, path, options) {
            options = options || {};
            var progress = typeof options.onProgress === "function" ? options.onProgress : null;
            var raw = host.download(text(url), text(path), JSON.stringify(options.headers || {}), progress);
            return jsonParse(raw, { success: false, error: "invalid host response" });
        },
        downloadSegments: function (segments, path, options) {
            options = options || {};
            var progress = typeof options.onProgress === "function" ? options.onProgress : null;
            var specs = (segments || []).map(function (item) {
                return typeof item === "string" ? { url: item } : item;
            });
            var raw = host.downloadSegments(JSON.stringify(specs), text(path), JSON.stringify(options), progress);
            return jsonParse(raw, { success: false, error: "invalid host response" });
        },
        exists: function (path) {
            var result = fileCall("exists", path);
            return result && result.exists === true;
        },
        delete: function (path) { return fileCall("delete", path); },
        read: function (path) { return fileCall("read", path); },
        readBytes: function (path) {
            var result = fileCall("readBytes", path);
            if (!result || !result.success || !result.data) return result;
            var binary = atob(result.data);
            var bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i) & 255;
            result.data = bytes;
            return result;
        },
        write: function (path, data) { return fileCall("write", path, text(data)); },
        writeBytes: function (path, data) { return fileCall("writeBytes", path, bytesToBase64(data)); },
        getSize: function (path) { return fileCall("getSize", path); },
        copy: function (from, to) { return fileCall("copy", from, to); },
        move: function (from, to) { return fileCall("move", from, to); },
        transformPatternedBlocks: function () {
            return { success: false, error: "transformPatternedBlocks is not supported by Tune" };
        }
    };

    // MARK: - Storage

    function storageCall(secret, method, key, value) {
        var raw = host.storage(String(method), text(key), value === undefined ? null : JSON.stringify(value), !!secret);
        return jsonParse(raw, { success: false, error: "invalid host response" });
    }

    globalThis.storage = {
        get: function (key, fallback) {
            var result = storageCall(false, "get", key);
            return result && result.found ? result.value : fallback;
        },
        set: function (key, value) {
            if (arguments.length < 2) return false;
            var result = storageCall(false, "set", key, value);
            return !!(result && result.success);
        },
        remove: function (key) {
            var result = storageCall(false, "remove", key);
            return !!(result && result.success);
        }
    };

    globalThis.credentials = {
        get: function (key, fallback) {
            var result = storageCall(true, "get", key);
            return result && result.found ? result.value : fallback;
        },
        store: function (key, value) {
            return storageCall(true, "set", key, value);
        },
        remove: function (key) { return storageCall(true, "remove", key); },
        has: function (key) {
            return !!storageCall(true, "has", key).found;
        }
    };

    // MARK: - Encoding

    globalThis.btoa = function (value) { return host.base64Encode(text(value)); };
    globalThis.atob = function (value) { return host.base64Decode(text(value)); };

    globalThis.TextEncoder = function () { this.encoding = "utf-8"; };
    globalThis.TextEncoder.prototype.encode = function (value) {
        return new Uint8Array(host.utf8Encode(text(value)));
    };
    globalThis.TextEncoder.prototype.encodeInto = function (value, destination) {
        var bytes = host.utf8Encode(text(value));
        var count = Math.min(bytes.length, destination.length);
        for (var i = 0; i < count; i++) destination[i] = bytes[i];
        return { read: text(value).length, written: count };
    };

    globalThis.TextDecoder = function (encoding) { this.encoding = encoding || "utf-8"; this.fatal = false; };
    globalThis.TextDecoder.prototype.decode = function (value) {
        if (value === undefined || value === null) return "";
        if (typeof value === "string") return value;
        return host.utf8Decode(Array.from(value, function (byte) { return byte & 255; }));
    };

    // MARK: - Timers / abort

    globalThis.setTimeout = function (callback, milliseconds) {
        if (typeof callback !== "function") return 0;
        return host.timerSet(callback, Number(milliseconds) || 0);
    };
    globalThis.clearTimeout = function (identifier) { host.timerClear(Number(identifier) || 0); };

    globalThis.AbortController = function () {
        var signal = { aborted: false, onabort: null, addEventListener: function () {}, removeEventListener: function () {} };
        this.signal = signal;
        this.abort = function () {
            if (signal.aborted) return;
            signal.aborted = true;
            if (typeof signal.onabort === "function") signal.onabort();
        };
    };

    // MARK: - Matching / utils

    globalThis.matching = {
        compareStrings: function (first, second) {
            if (arguments.length < 2) return 0;
            return host.compareStrings(text(first), text(second));
        },
        compareDuration: function (first, second, tolerance) {
            if (arguments.length < 2) return false;
            return host.compareDuration(Number(first) || 0, Number(second) || 0,
                tolerance === undefined ? 3000 : Number(tolerance) || 0);
        },
        normalizeString: function (value) { return host.normalize(text(value)); }
    };

    function formatLog(args) {
        var values = [];
        for (var i = 0; i < args.length && i < 8; i++) {
            var value = args[i];
            if (typeof value === "string") values.push(value);
            else if (value instanceof Error) values.push(value.message || String(value));
            else {
                try { values.push(JSON.stringify(value)); }
                catch (e) { values.push(String(value)); }
            }
        }
        return values.join(" ").slice(0, 4000);
    }

    globalThis.log = {
        debug: function () { host.log("DEBUG", formatLog(arguments)); },
        info: function () { host.log("INFO", formatLog(arguments)); },
        warn: function () { host.log("WARN", formatLog(arguments)); },
        error: function () { host.log("ERROR", formatLog(arguments)); }
    };
    globalThis.console = {
        log: function () { host.log("INFO", formatLog(arguments)); },
        warn: function () { host.log("WARN", formatLog(arguments)); },
        error: function () { host.log("ERROR", formatLog(arguments)); }
    };

    globalThis.utils = {
        isDownloadCancelled: function () { return host.cancelled(); },
        isRequestCancelled: function () { return host.cancelled(); },
        randomUserAgent: function () { return info.randomUserAgent || ""; },
        appVersion: function () { return info.appVersion || ""; },
        appUserAgent: function () { return info.appUserAgent || ""; },
        setDownloadStatus: function () { return true; },
        getResolutionRemainingMs: function () { return Number(info.resolutionRemainingMs) || 30000; },
        sleep: function (milliseconds) { return host.sleep(Number(milliseconds) || 0); },
        base64Encode: function (value) { return host.base64Encode(text(value)); },
        base64Decode: function (value) { return host.base64Decode(text(value)); },
        md5: function (value) { return host.hash("md5", text(value), "", false); },
        sha256: function (value) { return host.hash("sha256", text(value), "", false); },
        hmacSHA256: function (message, key) { return host.hash("hmac-sha256", text(message), text(key), false); },
        hmacSHA256Base64: function (message, key) { return host.hash("hmac-sha256", text(message), text(key), true); },
        hmacSHA1: function (key, message) { return host.hash("hmac-sha1", text(message), text(key), false); },
        parseJSON: function (value) { try { return JSON.parse(text(value)); } catch (e) { return undefined; } },
        stringifyJSON: function (value) { try { return JSON.stringify(value); } catch (e) { return ""; } },
        encrypt: function (data, key) { return jsonParse(host.crypt("encrypt", text(data), text(key)), { success: false }); },
        decrypt: function (data, key) { return jsonParse(host.crypt("decrypt", text(data), text(key)), { success: false }); },
        generateKey: function (length) { return jsonParse(host.generateKey(Number(length) || 32), { success: false }); },
        encryptBlockCipher: function (data, options) {
            return jsonParse(host.blockTransform("encrypt", JSON.stringify({ data: data, options: options || {} })), { success: false });
        },
        decryptBlockCipher: function (data, options) {
            return jsonParse(host.blockTransform("decrypt", JSON.stringify({ data: data, options: options || {} })), { success: false });
        },
        decryptCTRSegments: function () {
            return { success: false, error: "decryptCTRSegments is not supported by Tune" };
        }
    };

    globalThis.ffmpeg = {
        getInfo: function (path) {
            return jsonParse(host.ffmpeg("info", JSON.stringify({ path: text(path) })), { success: false, error: "unsupported" });
        },
        convert: function (input, output, options) {
            return jsonParse(host.ffmpeg("convert", JSON.stringify({
                input: text(input), output: text(output), options: options || {}
            })), { success: false, error: "unsupported" });
        }
    };

    globalThis.registerExtension = function (value) {
        globalThis.extension = value;
    };
})();
