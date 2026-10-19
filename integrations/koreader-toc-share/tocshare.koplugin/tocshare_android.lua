-- Stock Android JNI only; no custom launcher or Kalamos bridge is required.
local Share = { INLINE_LIMIT = 256 * 1024 }
-- Keep owned text files available for delayed receivers, just like cover previews.
local function textFile(text)
    local cache = require("datastorage"):getDataDir() .. "/cache"
    require("util").makePath(cache)
    local lfs = require("libs/libkoreader-lfs")
    for name in lfs.dir(cache) do
        if name:match("^tocshare%-text%-%d+%.txt$") then
            local attributes = lfs.attributes(cache .. "/" .. name)
            if attributes and attributes.mode == "file" and os.time() - attributes.modification > 86400 then
                os.remove(cache .. "/" .. name)
            end
        end
    end
    local path = cache .. "/tocshare-text-" .. tostring(math.random(1, 2147483647)) .. ".txt"
    local file = assert(io.open(path, "wb"))
    local ok, err = file:write(text)
    local closed = file:close()
    if not ok or not closed then os.remove(path); error(err or "Could not save shared text") end
    return path
end
function Share.send(text, reason, title, metadata, coverPath)
    local streamPath = #text > Share.INLINE_LIMIT and textFile(text) or nil
    local android = require("android")
    local ffi = require("ffi")
    local rapidjson = require("rapidjson")
    local succeeded, result = android.jni:context(android.app.activity.vm, function(jni)
        local env, refs = jni.env, {}
        local function check()
            if env[0].ExceptionCheck(env) ~= 0 then
                env[0].ExceptionClear(env)
                error("Android sharing failed")
            end
        end
        local function keep(value)
            check()
            assert(value ~= nil and value ~= ffi.NULL, "Android object unavailable")
            refs[#refs+1] = value
            return value
        end
        local function str(value) return keep(env[0].NewStringUTF(env, value)) end
        -- KOReader's convenience JNI calls invoke immediately after lookup. Check first:
        -- Android aborts the process if a failed lookup leaves an exception pending.
        local function method(object, name, signature)
            local class = keep(env[0].GetObjectClass(env, object))
            local id = env[0].GetMethodID(env, class, name, signature)
            check(); assert(id ~= nil and id ~= ffi.NULL, "Android method unavailable")
            return id
        end
        local function objectCall(object, name, signature, ...)
            local id = method(object, name, signature)
            return env[0].CallObjectMethod(env, object, id, ...)
        end
        local function voidCall(object, name, signature, ...)
            local id = method(object, name, signature)
            env[0].CallVoidMethod(env, object, id, ...)
            check()
        end
        local function staticCall(name, method_name, signature, ...)
            local class = keep(env[0].FindClass(env, name))
            local id = env[0].GetStaticMethodID(env, class, method_name, signature)
            check(); assert(id ~= nil and id ~= ffi.NULL, "Android static method unavailable")
            return env[0].CallStaticObjectMethod(env, class, id, ...)
        end
        local ok, result = pcall(function()
            local class = keep(env[0].FindClass(env, "android/content/Intent"))
            local constructor = env[0].GetMethodID(env, class, "<init>", "(Ljava/lang/String;)V")
            check(); assert(constructor ~= nil and constructor ~= ffi.NULL)
            local args = ffi.new("jvalue[1]"); args[0].l = str("android.intent.action.SEND")
            local intent = keep(env[0].NewObjectA(env, class, constructor, args))
            local function extra(key, value)
                keep(objectCall(intent, "putExtra", "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;", str(key), str(value)))
            end
            if not streamPath then extra("android.intent.extra.TEXT", text) end
            extra("android.intent.extra.TITLE", title)
            extra("android.intent.extra.SUBJECT", title)
            extra("org.koreader.extra.EXCERPT_METADATA", rapidjson.encode(metadata))
            keep(objectCall(intent, "setType", "(Ljava/lang/String;)Landroid/content/Intent;", str("text/plain")))
            -- AndroidX must be resolved through the Activity loader on the attached Lua thread.
            local function contentUri(path)
                local loader = keep(objectCall(android.app.activity.clazz, "getClassLoader", "()Ljava/lang/ClassLoader;"))
                local provider = keep(objectCall(loader, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;", str("androidx.core.content.FileProvider")))
                local package_name = keep(objectCall(android.app.activity.clazz, "getPackageName", "()Ljava/lang/String;"))
                local chars = env[0].GetStringUTFChars(env, package_name, nil)
                check(); assert(chars ~= nil and chars ~= ffi.NULL)
                local authority = ffi.string(chars) .. ".provider"
                env[0].ReleaseStringUTFChars(env, package_name, chars)
                local file_class = keep(env[0].FindClass(env, "java/io/File"))
                local constructor = env[0].GetMethodID(env, file_class, "<init>", "(Ljava/lang/String;)V")
                check(); assert(constructor ~= nil and constructor ~= ffi.NULL)
                local args = ffi.new("jvalue[1]"); args[0].l = str(path)
                local file = keep(env[0].NewObjectA(env, file_class, constructor, args))
                local id = env[0].GetStaticMethodID(env, provider, "getUriForFile", "(Landroid/content/Context;Ljava/lang/String;Ljava/io/File;)Landroid/net/Uri;")
                check(); assert(id ~= nil and id ~= ffi.NULL)
                local uri_args = ffi.new("jvalue[3]")
                uri_args[0].l = android.app.activity.clazz; uri_args[1].l = str(authority); uri_args[2].l = file
                return keep(env[0].CallStaticObjectMethodA(env, provider, id, uri_args))
            end
            local function uriClip(uri)
                local resolver = keep(objectCall(android.app.activity.clazz, "getContentResolver", "()Landroid/content/ContentResolver;"))
                return keep(staticCall("android/content/ClipData", "newUri",
                    "(Landroid/content/ContentResolver;Ljava/lang/CharSequence;Landroid/net/Uri;)Landroid/content/ClipData;", resolver, str(title), uri))
            end
            local clip
            if streamPath then
                local uri = contentUri(streamPath)
                keep(objectCall(intent, "putExtra", "(Ljava/lang/String;Landroid/os/Parcelable;)Landroid/content/Intent;", str("android.intent.extra.STREAM"), uri))
                clip = uriClip(uri)
                voidCall(intent, "setClipData", "(Landroid/content/ClipData;)V", clip)
                keep(objectCall(intent, "addFlags", "(I)Landroid/content/Intent;", ffi.new("jint", 1)))
            end
            if coverPath then
                local preview_ok = pcall(function()
                    local uri = contentUri(coverPath)
                    if clip then
                        -- Both URIs must be in ClipData to grant access to the text and preview.
                        local class = keep(env[0].FindClass(env, "android/content/ClipData$Item"))
                        local constructor = env[0].GetMethodID(env, class, "<init>", "(Landroid/net/Uri;)V")
                        check(); assert(constructor ~= nil and constructor ~= ffi.NULL)
                        local args = ffi.new("jvalue[1]"); args[0].l = uri
                        local item = keep(env[0].NewObjectA(env, class, constructor, args))
                        voidCall(clip, "addItem", "(Landroid/content/ClipData$Item;)V", item)
                    else
                        clip = uriClip(uri)
                        voidCall(intent, "setClipData", "(Landroid/content/ClipData;)V", clip)
                    end
                    keep(objectCall(intent, "setDataAndType", "(Landroid/net/Uri;Ljava/lang/String;)Landroid/content/Intent;", uri, str("text/plain")))
                    keep(objectCall(intent, "addFlags", "(I)Landroid/content/Intent;", ffi.new("jint", 1)))
                end)
                if not preview_ok then
                    if env[0].ExceptionCheck(env) ~= 0 then env[0].ExceptionClear(env) end
                    require("logger").warn("TOC share: standard cover URI unavailable; retaining embedded cover metadata")
                end
            end
            local chooser = keep(staticCall("android/content/Intent", "createChooser",
                "(Landroid/content/Intent;Ljava/lang/CharSequence;)Landroid/content/Intent;", intent, str(reason)))
            voidCall(android.app.activity.clazz, "startActivity", "(Landroid/content/Intent;)V", chooser)
            check()
            return true
        end)
        for i=#refs,1,-1 do env[0].DeleteLocalRef(env, refs[i]) end
        return ok, result
    end)
    -- Return through JNI:context before reporting an error, so it always detaches the thread.
    if not succeeded then error(result) end
    return result
end
return Share
