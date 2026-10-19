package.preload.logger=function() return {warn=function() end} end
local root=assert(arg[1]);package.path=root..'/?.lua;'..package.path
package.preload.datastorage=function() return {getDataDir=function() return '/tmp' end} end
package.preload.util=function() return {makePath=function(path) assert(os.execute('mkdir -p ' .. path)) end} end
local stale='/tmp/cache/tocshare-cover-123.jpg'
package.preload['libs/libkoreader-lfs']=function() return {
 dir=function() local names={'tocshare-cover-123.jpg','other-cover.jpg','tocshare-text-123.txt'};local i=0;return function() i=i+1;return names[i] end end,
 attributes=function() return {mode='file',modification=os.time()-86401} end,
} end
local metadata=require('tocshare_metadata')
local tests=0
local function test(label,f) f();tests=tests+1;print('ok metadata '..tests..' - '..label) end
test('book and chapter metadata works when there is no cover',function()
 local value=metadata.build({doc_props={title='A book',authors='An author'},document={}},'Chapter 2')
 assert(value.schema=='org.koreader.excerpt/v1' and value.title=='Chapter 2')
 assert(value.bookTitle=='A book' and value.authors=='An author' and not value.thumbnailBase64)
end)
test('cover decode failure never loses metadata',function()
 local value=metadata.build({document={getCoverPageImage=function() error('bad cover') end}},'Section')
 assert(value.title=='Section' and not value.thumbnailBase64)
end)
test('cover is resized and retained for delayed readers; expired owned previews are removed',function()
 local freed=0;local temp
 package.preload.mime=function() return {b64=function(value) assert(value=='jpeg');return 'anBlZw==' end} end
 local scaled={writeToFile=function(_,path,format,quality)
  temp=path;assert(format=='jpg' and quality==75);local f=assert(io.open(path,'wb'));f:write('jpeg');f:close();return true
 end,free=function() freed=freed+1 end}
 local cover={getWidth=function() return 1000 end,getHeight=function() return 2000 end,
 scale=function(_,width,height) assert(width==110 and height==220);return scaled end,
 free=function() freed=freed+1 end}
 require('util').makePath('/tmp/cache')
 local f=assert(io.open(stale,'wb'));f:write('old');f:close()
 local value,path=metadata.build({document={getCoverPageImage=function() return cover end}},'Title')
 local kept=assert(io.open(temp,'rb'));kept:close()
 assert(value.thumbnailBase64=='anBlZw==' and freed==2 and path==temp and io.open(stale,'rb')==nil)
 os.remove(temp)
end)
-- Exercise the actual JNI sender through a constrained fake platform; inspect intent contents,
-- chooser use, reference cleanup and native exceptions without requiring a physical Android UI.
local extras, refs, deleted, chooser, launched = {},0,0,false,false
local pending, fail_lookup, fail_launch = false,nil,false
local clipset, dataset, granted=false,false,false
local detached=0
local filePaths, clipUris, largestString = {}, {}, 0
local function ref(kind) refs=refs+1;return {kind=kind} end
-- Exact SDK method descriptors, rather than mocks that accept arbitrary signatures.
local signatures={
 ['<init>']='(Ljava/lang/String;)V',
 putExtra='(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;',
 setType='(Ljava/lang/String;)Landroid/content/Intent;',
 getClassLoader='()Ljava/lang/ClassLoader;',
 loadClass='(Ljava/lang/String;)Ljava/lang/Class;',
 getPackageName='()Ljava/lang/String;',
 getContentResolver='()Landroid/content/ContentResolver;',
 setClipData='(Landroid/content/ClipData;)V',
 addItem='(Landroid/content/ClipData$Item;)V',
 setDataAndType='(Landroid/net/Uri;Ljava/lang/String;)Landroid/content/Intent;',
 addFlags='(I)Landroid/content/Intent;',
 startActivity='(Landroid/content/Intent;)V',
 getUriForFile='(Landroid/content/Context;Ljava/lang/String;Ljava/io/File;)Landroid/net/Uri;',
 newUri='(Landroid/content/ContentResolver;Ljava/lang/CharSequence;Landroid/net/Uri;)Landroid/content/ClipData;',
 createChooser='(Landroid/content/Intent;Ljava/lang/CharSequence;)Landroid/content/Intent;',
}
local function lookup(_,class,name,signature)
 assert(not pending,'lookup called with pending exception')
 local expected = signatures[name]
 if name=='<init>' and class.kind=='android/content/ClipData$Item' then expected='(Landroid/net/Uri;)V' end
 if name=='putExtra' and signature=='(Ljava/lang/String;Landroid/os/Parcelable;)Landroid/content/Intent;' then expected=signature end
 assert(expected==signature,'wrong SDK descriptor for '..name..': '..signature)
 if fail_lookup==name then pending=true;return nil end
 return {name=name,signature=signature}
end
local api={
 ExceptionCheck=function() return pending and 1 or 0 end,
 ExceptionClear=function() pending=false end,
 NewStringUTF=function(_,value) assert(not pending);largestString=math.max(largestString,#value);assert(#value<=256*1024);return ref(value) end,
 FindClass=function(_,name) assert(not pending);return ref(name) end,
 GetObjectClass=function(_,object) assert(not pending);return ref(object.kind..'Class') end,
 GetStringUTFChars=function(_,value) assert(not pending);return value.kind end,
 ReleaseStringUTFChars=function() assert(not pending) end,
 GetStaticMethodID=lookup,
 GetMethodID=lookup,
 CallStaticObjectMethodA=function(_,class,method,args)
  assert(not pending and class.kind=='FileProvider' and method.name=='getUriForFile')
  assert(args[1].l.kind=='org.koreader.launcher.debug.provider' and args[2].l.kind=='File')
  local path=args[2].l.path
  return ref(path:match('%.txt$') and 'content://text' or 'content://cover')
 end,
 NewObjectA=function(_,class,method,args)
  assert(not pending and method.name=='<init>')
  if class.kind=='java/io/File' then
   local path=args[0].l.kind;filePaths[#filePaths+1]=path
   local value=ref('File');value.path=path;return value
  end
  if class.kind=='android/content/ClipData$Item' then
   local value=ref('ClipItem');value.uri=args[0].l.kind;return value
  end
  assert(args[0].l.kind=='android.intent.action.SEND');return ref('Intent')
 end,
 DeleteLocalRef=function() assert(not pending);deleted=deleted+1 end,
}
function api.CallObjectMethod(_,object,method,key,value)
 assert(not pending,'JNI invocation attempted with pending exception')
 local name=method.name
 if name=='putExtra' then extras[key.kind]=value.kind
 elseif name=='setType' then assert(key.kind=='text/plain')
 elseif name=='getClassLoader' then return ref('Loader')
 elseif name=='loadClass' then assert(key.kind=='androidx.core.content.FileProvider');return ref('FileProvider')
 elseif name=='getPackageName' then return ref('org.koreader.launcher.debug')
 elseif name=='getContentResolver' then return ref('Resolver')
 elseif name=='setDataAndType' then assert(key.kind=='content://cover' and value.kind=='text/plain');dataset=true
 elseif name=='addFlags' then assert(key==1);granted=true
 else error(name) end
 return ref('Intent')
end
function api.CallStaticObjectMethod(_,class,method,intent,reason,uri)
 assert(not pending)
 if class.kind=='android/content/ClipData' then assert(method.name=='newUri' and intent.kind=='Resolver');clipUris={uri.kind};return ref('Clip') end
 assert(class.kind=='android/content/Intent' and method.name=='createChooser');chooser=true;return ref('Chooser')
end
function api.CallVoidMethod(_,object,method,value)
 assert(not pending and method.signature:sub(-1)=='V')
 if method.name=='addItem' then assert(object.kind=='Clip');clipUris[#clipUris+1]=value.uri;return end
 if method.name=='setClipData' then assert(value.kind=='Clip');clipset=true;return end
 assert(method.name=='startActivity' and chooser and value.kind=='Chooser')
 if fail_launch then pending=true else launched=true end
end
local jni={env=setmetatable({},{__index=function(_,k) if k==0 then return api end end})}
package.preload.android=function() return {app={activity={vm={},clazz={kind='Activity'}}},jni={context=function(_,vm,action)
 local ok,result=action(jni);detached=detached+1;return ok,result
end}} end
package.preload.ffi=function() return {NULL='NULL',string=function(value) return value end,new=function(kind,value) if kind=='jint' then return value end;return {[0]={},[1]={},[2]={}} end} end
package.preload.rapidjson=function() return {encode=function(value) assert(value.title=='Chapter');return 'metadata-json' end} end
local share=require('tocshare_android')
test('stock JNI builds ACTION_SEND with exact text, title, subject, metadata and chooser',function()
 assert(share.send('Only chapter text','Share excerpt','Book — Chapter',{title='Chapter'}))
 assert(launched and chooser and extras['android.intent.extra.TEXT']=='Only chapter text')
 assert(extras['android.intent.extra.TITLE']=='Book — Chapter' and extras['android.intent.extra.SUBJECT']=='Book — Chapter')
 assert(extras['org.koreader.extra.EXCERPT_METADATA']=='metadata-json')
 assert(refs==deleted and detached==1)
end)
test('SDK void setClipData, app-loaded FileProvider, text MIME and read grant',function()
 assert(share.send('Text','Share','Title',{title='Chapter'},'/cover.jpg'))
 assert(clipset and dataset and granted and refs==deleted and detached==2)
end)
test('missing optional preview method clears exception before further JNI invocation',function()
 fail_lookup='setClipData';launched=false;clipset=false
 assert(share.send('Text','Share','Title',{title='Chapter'},'/cover.jpg'))
 assert(launched and not clipset and not pending and refs==deleted and detached==3)
 fail_lookup=nil
end)
test('missing required method never invokes a null method ID and still detaches',function()
 fail_lookup='putExtra';launched=false
 assert(not pcall(share.send,'Text','Share','Title',{title='Chapter'}))
 assert(not launched and not pending and refs==deleted and detached==4)
 fail_lookup=nil
end)
test('native launch failure clears exceptions, frees refs and detaches before stock fallback',function()
 fail_launch=true
 assert(not pcall(share.send,'Text','Share','Title',{title='Chapter'}))
 assert(not pending and refs==deleted and detached==5)
end)
test('four MiB text uses a complete owned file and only a URI crosses JNI',function()
 fail_launch=false;extras={};largestString=0
 local text=string.rep('x',4*1024*1024-4)..'END!'
 local staleText='/tmp/cache/tocshare-text-123.txt'
 local old=assert(io.open(staleText,'wb'));old:write('old');old:close()
 assert(share.send(text,'Share book text','Book',{title='Chapter'},'/cover.jpg'))
 assert(extras['android.intent.extra.STREAM']=='content://text' and not extras['android.intent.extra.TEXT'])
 assert(clipUris[1]=='content://text' and clipUris[2]=='content://cover' and granted)
 local path=filePaths[#filePaths-1];local file=assert(io.open(path,'rb'))
 assert(file:read('*a')==text);file:close();os.remove(path)
 assert(not io.open(staleText,'rb') and largestString<1024 and refs==deleted)
end)
test('exact inline threshold preserves ordinary direct text sharing',function()
 extras={};local text=string.rep('x',256*1024)
 assert(share.send(text,'Share','Book',{title='Chapter'}))
 assert(extras['android.intent.extra.TEXT']==text and not extras['android.intent.extra.STREAM'])
end)
test('optional cover failure cannot remove the required file grant',function()
 extras={};fail_lookup='addItem';launched=false
 assert(share.send(string.rep('x',256*1024+1),'Share','Book',{title='Chapter'},'/cover.jpg'))
 assert(launched and extras['android.intent.extra.STREAM']=='content://text' and clipUris[1]=='content://text' and not pending)
 fail_lookup=nil;os.remove(filePaths[#filePaths-1]);assert(refs==deleted)
end)
test('missing required stream method fails cleanly without an oversized inline payload',function()
 extras={};fail_lookup='setClipData';launched=false
 assert(not pcall(share.send,string.rep('x',256*1024+1),'Share','Book',{title='Chapter'}))
 assert(not launched and not extras['android.intent.extra.TEXT'] and not pending and refs==deleted)
 fail_lookup=nil;os.remove(filePaths[#filePaths])
end)
print('Passed '..tests..' metadata/JNI scenarios')
