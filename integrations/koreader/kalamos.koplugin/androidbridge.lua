-- JNI scaffolding is derived from Android App Launcher for KOReader (MIT).
-- Copyright (c) 2025 Alexander Mikhailian. See THIRD_PARTY_NOTICES.md.
local ffi = require("ffi")
local rapidjson = require("rapidjson")

local Bridge = {}
local ok_android, android = pcall(require, "android")

local function exception(env, operation)
    if env[0].ExceptionCheck(env) == 0 then return nil end
    env[0].ExceptionDescribe(env); env[0].ExceptionClear(env)
    return "JNI exception while " .. operation
end

local function invoke(method, signature, args)
    if not ok_android or not android.jni or not android.app or not android.app.activity then
        return nil, "Kalamos Android bridge is unavailable"
    end
    return android.jni:context(android.app.activity.vm, function(jni)
        local env, refs = jni.env, {}
        local function keep(ref)
            if ref ~= nil and ref ~= ffi.NULL then refs[#refs + 1] = ref end
            return ref
        end
        local function cleanup()
            for i = #refs, 1, -1 do env[0].DeleteLocalRef(env, refs[i]) end
        end
        -- MainActivity is already a live application object, so invoking its
        -- narrow wrapper methods avoids FindClass and vendor class-loader quirks.
        local activity = android.app.activity.clazz
        local class = keep(env[0].GetObjectClass(env, activity))
        local err = exception(env, "finding the Android activity class")
        if err or class == nil or class == ffi.NULL then
            cleanup(); return nil, err or "Android activity class is unavailable"
        end
        local method_id = env[0].GetMethodID(env, class, method, signature)
        err = exception(env, "finding " .. method)
        if err or method_id == nil then cleanup(); return nil, err or "Kalamos bridge method is unavailable" end
        local jargs = {}
        for _, value in ipairs(args or {}) do jargs[#jargs + 1] = keep(env[0].NewStringUTF(env, value)) end
        local result = keep(env[0].CallObjectMethod(env, activity, method_id, unpack(jargs)))
        err = exception(env, "calling " .. method)
        if err or result == nil or result == ffi.NULL then cleanup(); return nil, err or "Empty Kalamos bridge response" end
        local chars = env[0].GetStringUTFChars(env, result, nil)
        local length = tonumber(env[0].GetStringUTFLength(env, result))
        local value = ffi.string(chars, length)
        env[0].ReleaseStringUTFChars(env, result, chars); cleanup()
        local parsed, decode_err = rapidjson.decode(value)
        return parsed, decode_err
    end)
end

local function invokeBoolean(method)
    if not ok_android or not android.jni or not android.app or not android.app.activity then
        return false
    end
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local activity = android.app.activity.clazz
        local class = env[0].GetObjectClass(env, activity)
        if class == nil or class == ffi.NULL then return false end
        local method_id = env[0].GetMethodID(env, class, method, "()Z")
        local err = exception(env, "finding " .. method)
        if err or method_id == nil then
            env[0].DeleteLocalRef(env, class)
            return false
        end
        local result = env[0].CallBooleanMethod(env, activity, method_id)
        err = exception(env, "calling " .. method)
        env[0].DeleteLocalRef(env, class)
        return not err and result ~= 0
    end)
end

local function invokeBooleanInt(method, value)
    if not ok_android or not android.jni or not android.app or not android.app.activity then
        return false
    end
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local activity = android.app.activity.clazz
        local class = env[0].GetObjectClass(env, activity)
        if class == nil or class == ffi.NULL then return false end
        local method_id = env[0].GetMethodID(env, class, method, "(I)Z")
        local err = exception(env, "finding " .. method)
        if err or method_id == nil then
            env[0].DeleteLocalRef(env, class)
            return false
        end
        local args = ffi.new("jvalue[1]")
        args[0].i = value
        local result = env[0].CallBooleanMethodA(env, activity, method_id, args)
        err = exception(env, "calling " .. method)
        env[0].DeleteLocalRef(env, class)
        return not err and result ~= 0
    end)
end

function Bridge.ping()
    return invoke("kalamosPing", "()Ljava/lang/String;", {})
end
function Bridge.startInk(bounds)
    return invoke("kalamosStartInk", "(Ljava/lang/String;)Ljava/lang/String;", { rapidjson.encode(bounds) })
end
function Bridge.penMotion(event)
    return invoke("kalamosPenMotion", "(Ljava/lang/String;)Ljava/lang/String;", { rapidjson.encode(event) })
end
function Bridge.stopInk()
    return invoke("kalamosStopInk", "()Ljava/lang/String;", {})
end
function Bridge.pauseInk()
    return invoke("kalamosPauseInk", "()Ljava/lang/String;", {})
end
function Bridge.drainInk()
    return invoke("kalamosDrainInk", "()Ljava/lang/String;", {})
end
function Bridge.isPenInputActive()
    return invokeBoolean("kalamosIsPenInputActive")
end
function Bridge.isPenInputDevice(device_id)
    return invokeBooleanInt("kalamosIsPenInputDevice", device_id)
end

return Bridge
