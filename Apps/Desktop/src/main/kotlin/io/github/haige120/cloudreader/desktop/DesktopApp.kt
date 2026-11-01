package io.github.haige120.cloudreader.desktop

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.haige120.cloudreader.core.application.AppDestination
import io.github.haige120.cloudreader.core.model.ChatRecord
import io.github.haige120.cloudreader.core.model.ChatMessage
import io.github.haige120.cloudreader.core.model.nowFoundationSeconds
import io.github.haige120.cloudreader.core.assistant.RemoteAssistant
import io.github.haige120.cloudreader.ui.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.collect
import io.github.haige120.cloudreader.core.application.SyncTrigger
import io.github.haige120.cloudreader.core.application.SyncRequestCoordinator
import java.awt.FileDialog
import java.awt.Frame
import java.nio.file.Path
import java.util.UUID

class SwingFilePicker : FilePicker {
    fun pickBooks(): List<Path> {
        val dialog = FileDialog(null as Frame?,"Import books",FileDialog.LOAD).apply {
            isMultipleMode=true
            filenameFilter=java.io.FilenameFilter { _,name -> name.substringAfterLast('.').lowercase() in BookFormat.entries.map{it.extension} }
        }
        return try { dialog.isVisible=true; dialog.files.map { it.toPath() } } finally { dialog.dispose() }
    }
    override fun pickBook():Path?=pickBooks().firstOrNull()
}

@Composable
@OptIn(kotlinx.coroutines.FlowPreview::class)
fun CloudReaderDesktopApp(repository: FileLibraryRepository, picker: SwingFilePicker, root:Path, externalImports:Pair<Long,List<Path>>? = null,
    initialDestination:AppDestination=AppDestination.LIBRARY, darkTheme:Boolean?=null) {
    val scope=rememberCoroutineScope()
    val settings=remember{DesktopSettings(root.resolve("settings.properties"))}
    val secrets=remember{DesktopSecrets(root,settings)}
    val aiService=remember{RemoteAssistant({secrets.read("ai.apiKey")})}
    val sync=remember{DesktopSync(repository,root.resolve("recovery/merge-candidates.jsonl"))}
    var destination by rememberSaveable { mutableStateOf(initialDestination) }
    var oauthBusy by remember { mutableStateOf(false) }
    var books by remember{mutableStateOf(repository.books())}
    var chats by remember{mutableStateOf(repository.chats())}
    var selected by remember{mutableStateOf<BookRecord?>(null)}
    var search by rememberSaveable{mutableStateOf("")}
    var favorites by rememberSaveable{mutableStateOf(false)}
    var syncStatus by remember{mutableStateOf("Your shelf is ready offline")}
    var activeId by rememberSaveable{mutableStateOf<String?>(null)}
    var contextBook by remember{mutableStateOf<BookRecord?>(null)}
    var excerpt by remember{mutableStateOf<String?>(null)}
    var includeContext by rememberSaveable{mutableStateOf(false)}
    var draft by rememberSaveable{mutableStateOf("")}
    var busy by remember{mutableStateOf(false)}
    var aiError by remember{mutableStateOf<String?>(null)}
    var requestJob by remember{mutableStateOf<Job?>(null)}
    val snackbar=remember{SnackbarHostState()}
    val changes=remember{kotlinx.coroutines.flow.MutableSharedFlow<Unit>(extraBufferCapacity=1,onBufferOverflow=kotlinx.coroutines.channels.BufferOverflow.DROP_OLDEST)}
    val requests=remember{SyncRequestCoordinator<String>{trigger->withContext(Dispatchers.IO){
        val stores=desktopStores(settings,secrets)
        if(stores.isEmpty()&&trigger!=SyncTrigger.MANUAL)"Your shelf is ready offline" else sync.sync(stores)
    }}}
    fun refresh(){books=repository.books();chats=repository.chats()}
    suspend fun synchronize(trigger:SyncTrigger){
        try{syncStatus=requests.request(trigger);refresh()}
        catch(cancelled:CancellationException){throw cancelled}
        catch(failure:Exception){syncStatus=failure.message?:"Sync needs attention"}
    }
    LaunchedEffect(Unit){changes.debounce(2000).collect{synchronize(SyncTrigger.LOCAL_CHANGE)}}
    LaunchedEffect(Unit){synchronize(SyncTrigger.FOREGROUND)}
    fun task(scheduleSync:Boolean=true,action:suspend()->Unit){scope.launch{try{withContext(Dispatchers.IO){action()};refresh();if(scheduleSync)changes.tryEmit(Unit)}catch(cancelled:CancellationException){throw cancelled}catch(failure:Exception){snackbar.showSnackbar(failure.message?:"The operation failed.")}}}
    fun open(book:BookRecord){selected=book;task{repository.opened(book.id)}}
    fun ask(book:BookRecord?,text:String?){contextBook=book;excerpt=text;activeId=null;includeContext=false;aiError=null;destination=AppDestination.ASSISTANT}
    fun imports(paths:List<Path>){task{
        val results=repository.accept(paths)
        val first=results.filterIsInstance<ImportResult.Imported>().firstOrNull()?.book
        withContext(Dispatchers.Main){first?.let(::open);snackbar.showSnackbar("Imported ${results.count{it is ImportResult.Imported}} · failed ${results.count{it !is ImportResult.Imported}}")}
    }}
    fun request(chat:ChatRecord){
        busy=true;aiError=null
        requestJob=scope.launch{
            try{
                val answer=withContext(Dispatchers.IO){
                    aiService.ask(settings.profile(),chat.messages,
                        if(chat.includeBookContext)chat.bookTitle else null, if(chat.includeBookContext)chat.selectedText else null, if(chat.includeBookContext)chat.bookContext else null)
                }
                withContext(Dispatchers.IO){repository.saveChat(chat.copy(messages=chat.messages+ChatMessage(UUID.randomUUID().toString().uppercase(),"assistant",answer,nowFoundationSeconds()),modifiedAt=nowFoundationSeconds()))}
                refresh();changes.tryEmit(Unit)
            }catch(cancelled:CancellationException){aiError="Request stopped. You can retry.";throw cancelled}
             catch(failure:Exception){aiError=failure.message?:"AI request failed"}
            finally{busy=false;requestJob=null}
        }
    }
    LaunchedEffect(externalImports?.first){externalImports?.second?.takeIf{it.isNotEmpty()}?.let(::imports)}
    DisposableEffect(Unit){onDispose{requestJob?.cancel()}}
    CloudReaderTheme(darkTheme = darkTheme ?: isSystemInDarkTheme()) {
        val reader=selected
        if(reader!=null){
            DesktopReader(reader,root.resolve("reader-cache"),settings,onClose={selected=null;refresh()},
                onPosition={fraction,location->task{repository.savePosition(reader.id,fraction,location)}},
                onAsk={text->selected=null;ask(reader,text)})
        }else CloudReaderShell(destination,{destination=it},snackbar){when(destination){
            AppDestination.LIBRARY->LibraryContent(books.map{it.portable()},search,favorites,syncStatus,{search=it},{favorites=!favorites},
                {imports(picker.pickBooks())},{scope.launch{synchronize(SyncTrigger.MANUAL)}},onOpen={portable->books.firstOrNull{it.id.value.equals(portable.id,true)}?.let(::open)},
                onAsk={portable->ask(books.firstOrNull{it.id.value.equals(portable.id,true)},null)},
                onFavorite={portable->task{repository.setFavorite(BookId(portable.id),!portable.isBookmarked)}},
                onRemove={portable->task{repository.remove(BookId(portable.id))}})
            AppDestination.ASSISTANT->{
                val active=chats.firstOrNull{it.id==activeId}
                AssistantContent(chats,active,draft,busy,includeContext,excerpt?:active?.selectedText?:contextBook?.title?:active?.bookTitle,aiError,
                    "${settings.profile().name} · ${settings.profile().model.ifBlank{"Set up a model in Settings"}}",
                    {draft=it},{id->requestJob?.cancel();activeId=id;contextBook=null;excerpt=null;includeContext=chats.first{it.id==id}.includeBookContext},
                    {requestJob?.cancel();activeId=null;contextBook=null;excerpt=null;includeContext=false;draft=""},
                    {includeContext=it;active?.let{chat->task{repository.saveChat(chat.copy(includeBookContext=it,modifiedAt=nowFoundationSeconds()))}}},
                    onSend={
                        val now=nowFoundationSeconds();val question=draft.trim()
                        val chat=(active?:ChatRecord(UUID.randomUUID().toString().uppercase(),question.take(60),bookID=contextBook?.id?.value,
                            bookTitle=contextBook?.title,selectedText=excerpt?.take(18000),createdAt=now,modifiedAt=now))
                            .let{it.copy(messages=it.messages+ChatMessage(UUID.randomUUID().toString().uppercase(),"user",question,now),includeBookContext=includeContext,modifiedAt=now)}
                        val source=contextBook
                        task{
                            val prepared=if(chat.includeBookContext&&chat.selectedText.isNullOrBlank()&&chat.bookContext.isNullOrBlank()&&source!=null)
                                chat.copy(bookContext=readDesktopBookContext(source))else chat
                            repository.saveChat(prepared);withContext(Dispatchers.Main){activeId=prepared.id;draft="";request(prepared)}
                        }
                    },onCancel={requestJob?.cancel()},onRetry={active?.let(::request)},onDelete={active?.let{chat->task{repository.removeChat(chat.id);withContext(Dispatchers.Main){activeId=null}}}})
            }
            AppDestination.SETTINGS->DesktopSettingsScreen(settings,secrets,oauthBusy,onConnect={provider,updates,passwords,result->
                if(!oauthBusy){oauthBusy=true;scope.launch{
                    try{
                        withContext(Dispatchers.IO){
                            if(provider=="googleDrive")saveDesktopSettings(settings,secrets,updates.filterKeys{it.startsWith("googleDrive.")},passwords.filterKeys{it.startsWith("googleDrive.")})
                            else settings.save(mapOf("$provider.appKey" to updates["$provider.appKey"].orEmpty().trim()))
                            DesktopOAuth(settings,secrets).connect(provider)
                        }
                        result(true,"Storage connected. Backup is enabled for this destination.");changes.tryEmit(Unit)
                    }catch(cancelled:CancellationException){throw cancelled}
                    catch(failure:Exception){result(false,failure.message?:"Storage connection failed. Try Connect again.")}
                    finally{oauthBusy=false}
                }}
            },onSave={updates,passwords,result->
                scope.launch{
                    try{
                        withContext(Dispatchers.IO){saveDesktopSettings(settings,secrets,updates,passwords)}
                        result(true,"Settings saved on this device");changes.tryEmit(Unit)
                    }catch(cancelled:CancellationException){throw cancelled}
                    catch(failure:Exception){result(false,failure.message?:"Settings could not be saved")}
                }
            })
        }}
    }
}

internal fun saveDesktopSettings(settings:DesktopSettings,secrets:DesktopSecrets,updates:Map<String,String>,passwords:Map<String,String>){
    val google=DesktopOAuth(settings,secrets)
    val useCustom=updates["googleDrive.useCustomCredentials"]?.toBooleanStrictOrNull()?:google.useCustomGoogleCredentials()
    val modeChanged=google.setGoogleConnectionMode(useCustom)
    val credentialsChanged=if(useCustom)google.saveGoogleCredentials(updates["googleDrive.clientID"].orEmpty(),passwords["googleDrive.clientSecret"].orEmpty())else false
    val preserved=updates.filterKeys{it !in setOf("googleDrive.clientID","googleDrive.useCustomCredentials","googleDrive.enabled")}
    settings.save(preserved+mapOf("googleDrive.enabled" to if(modeChanged||credentialsChanged)"false"else updates["googleDrive.enabled"].orEmpty()))
    passwords.filterKeys{it!="googleDrive.clientSecret"}.filterValues{it.isNotBlank()}.forEach{(key,value)->secrets.write(key,value)}
}

@Composable
internal fun DesktopSettingsScreen(settings:DesktopSettings,secrets:DesktopSecrets,busy:Boolean=false,
    onConnect:(String,Map<String,String>,Map<String,String>,(Boolean,String)->Unit)->Unit,
    onSave:(Map<String,String>,Map<String,String>,(Boolean,String)->Unit)->Unit){
    val fields=listOf("folder.path","folder.enabled","webdav.url","webdav.user","webdav.enabled","ai.name","ai.protocol","ai.model","ai.endpoint",
        "credentials.plaintext","googleDrive.clientID","googleDrive.enabled","googleDrive.useCustomCredentials","dropbox.appKey","dropbox.enabled","pcloud.appKey","pcloud.enabled",
        "sftp.enabled","sftp.host","sftp.port","sftp.username","sftp.directory","sftp.hostKey")
    var values by remember{mutableStateOf(fields.associateWith{settings.get(it,when(it){"ai.name"->"My AI";"ai.protocol"->"openAIResponses";"googleDrive.useCustomCredentials"->DesktopOAuth(settings,secrets).useCustomGoogleCredentials().toString();else->""})})}
    var passwords by remember{mutableStateOf(mapOf("ai.apiKey" to "","webdav.password" to "","googleDrive.clientSecret" to "","sftp.password" to ""))}
    var advancedGoogle by remember{mutableStateOf(false)}
    var feedback by remember{mutableStateOf<Pair<Boolean,String>?>(null)}
    var saving by remember{mutableStateOf(false)}
    fun edit(key:String,value:String){values=values+(key to value)}
    val useCustomGoogle=values["googleDrive.useCustomCredentials"]=="true"
    fun result(success:Boolean,message:String,clearPasswords:Boolean=false){
        feedback=success to message;saving=false
        edit("googleDrive.enabled",settings.get("googleDrive.enabled"))
        if(success&&clearPasswords)passwords=passwords.mapValues{""}
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
        Text("Settings",fontFamily=FontFamily.Serif,fontSize=30.sp)
        Text("No account required. Storage connections and AI are optional.")
        feedback?.let{(success,message)->ConnectionStatus(message,needsAttention=!success)}
        Text("Sync destinations",fontFamily=FontFamily.Serif,fontSize=22.sp)
        Text("Connect Google Drive, choose your account and allow backup access. No client ID or secret is needed for the standard connection.",color=MaterialTheme.colorScheme.onSurfaceVariant)
        if(useCustomGoogle){
            Text("This device uses a custom Google project. Its saved credentials are retained.")
            TextButton(onClick={edit("googleDrive.useCustomCredentials","false")},enabled=!busy&&!saving){Text("Use standard Google connection")}
        }
        listOf("googleDrive" to "Google Drive","dropbox" to "Dropbox","pcloud" to "pCloud").forEach{(id,name)->
            SyncDestinationCard(name,if(values["$id.enabled"]=="true")"Selected for backup"else"Not selected",values["$id.enabled"]=="true",enabled=!busy&&!saving,
                onSelected={edit("$id.enabled",it.toString())}){
                TextButton(onClick={feedback=null;onConnect(id,values.toMap(),passwords.toMap()){success,message->
                    result(success,message)
                    edit("$id.enabled",settings.get("$id.enabled"))
                    if(success&&id=="googleDrive")passwords=passwords+("googleDrive.clientSecret" to "")
                }},enabled=!busy&&!saving){Text(if(busy)"Connecting…"else"Connect $name")}
            }
            val key=if(id=="googleDrive")"googleDrive.clientID" else "$id.appKey"
            if(id!="googleDrive")OutlinedTextField(values[key].orEmpty(),{edit(key,it)},label={Text("$name app key")},modifier=Modifier.fillMaxWidth())
        }
        TextButton(onClick={advancedGoogle=!advancedGoogle}){Text(if(advancedGoogle)"Hide advanced Google settings"else"Advanced Google settings (optional)")}
        if(advancedGoogle){
            Row{Switch(useCustomGoogle,{edit("googleDrive.useCustomCredentials",it.toString())},enabled=!busy&&!saving);Text("Use my own Google Cloud project",modifier=Modifier.padding(12.dp))}
            Text("Standard connection uses CloudReader's app registration. A custom project is optional for developers and self-built apps. Changing modes needs a new connection; your library and saved custom credentials are kept.",color=MaterialTheme.colorScheme.onSurfaceVariant)
            if(useCustomGoogle){
                OutlinedTextField(values["googleDrive.clientID"].orEmpty(),{edit("googleDrive.clientID",it)},label={Text("Google OAuth client ID (Desktop app)")},singleLine=true,modifier=Modifier.fillMaxWidth())
                OutlinedTextField(passwords["googleDrive.clientSecret"].orEmpty(),{passwords=passwords+("googleDrive.clientSecret" to it)},label={Text("Desktop client secret (blank keeps saved value for this ID)")},visualTransformation=PasswordVisualTransformation(),singleLine=true,modifier=Modifier.fillMaxWidth())
                Text("Use a Desktop app client, not a Web application or Android client. Enable the Drive API and configure consent/test users in that project. Save or Connect to apply.",color=MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Text("Dropbox/pCloud registrations must permit a loopback redirect on 127.0.0.1. Authorization opens only when you choose Connect.",style=MaterialTheme.typography.bodyMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
        SyncDestinationCard("Folder","Back up to a folder on this computer",values["folder.enabled"]=="true",onSelected={edit("folder.enabled",it.toString())})
        OutlinedTextField(values["folder.path"].orEmpty(),{edit("folder.path",it)},label={Text("Folder path")},modifier=Modifier.fillMaxWidth())
        SyncDestinationCard("HTTPS WebDAV","Use your own HTTPS server",values["webdav.enabled"]=="true",onSelected={edit("webdav.enabled",it.toString())})
        listOf("webdav.url" to "HTTPS WebDAV URL","webdav.user" to "WebDAV username").forEach{(key,label)->OutlinedTextField(values[key].orEmpty(),{edit(key,it)},label={Text(label)},modifier=Modifier.fillMaxWidth())}
        OutlinedTextField(passwords["webdav.password"].orEmpty(),{passwords=passwords+("webdav.password" to it)},label={Text("WebDAV password (blank keeps saved value)")},visualTransformation=PasswordVisualTransformation(),modifier=Modifier.fillMaxWidth())
        Text("Sync transfers books, progress, favorites, deletions and saved conversations. With schema v1, sync your devices sequentially; simultaneous writers can overwrite unseen changes.",style=MaterialTheme.typography.bodySmall)
        SyncDestinationCard("SFTP","Connect with a pinned server public key",values["sftp.enabled"]=="true",onSelected={edit("sftp.enabled",it.toString())})
        listOf("sftp.host" to "SFTP host","sftp.port" to "Port (22)","sftp.username" to "SFTP username","sftp.directory" to "Remote directory (CloudReader)","sftp.hostKey" to "OpenSSH host public key").forEach{(key,label)->OutlinedTextField(values[key].orEmpty(),{edit(key,it)},label={Text(label)},modifier=Modifier.fillMaxWidth())}
        OutlinedTextField(passwords["sftp.password"].orEmpty(),{passwords=passwords+("sftp.password" to it)},label={Text("SFTP password (blank keeps saved value)")},visualTransformation=PasswordVisualTransformation(),modifier=Modifier.fillMaxWidth())
        Text("Remote AI",fontFamily=FontFamily.Serif,fontSize=22.sp)
        listOf("ai.name" to "Profile name","ai.model" to "Model ID","ai.endpoint" to "Custom HTTPS endpoint (optional)").forEach{(key,label)->OutlinedTextField(values[key].orEmpty(),{edit(key,it)},label={Text(label)},modifier=Modifier.fillMaxWidth())}
        Column{listOf("openAIResponses","openAIChatCompletions","anthropicMessages").forEach{protocol->TextButton(onClick={edit("ai.protocol",protocol)}){Text((if(values["ai.protocol"]==protocol)"✓ " else "")+protocol)}}}
        OutlinedTextField(passwords["ai.apiKey"].orEmpty(),{passwords=passwords+("ai.apiKey" to it)},label={Text("API key (blank keeps saved value)")},visualTransformation=PasswordVisualTransformation(),modifier=Modifier.fillMaxWidth())
        Row{Checkbox(values["credentials.plaintext"]=="true",{edit("credentials.plaintext",it.toString())});Text("Allow plaintext credential fallback on this device")}
        Text("Off by default. Enable only if no OS secret service is available and you accept credentials being readable in your local credential file. Restart after changing this option.",style=MaterialTheme.typography.bodySmall)
        Text(secrets.description,style=MaterialTheme.typography.bodySmall)
        Button(onClick={saving=true;onSave(values.toMap(),passwords.toMap()){success,message->result(success,message,clearPasswords=true)}},enabled=!busy&&!saving){Text(if(saving)"Saving…"else"Save settings")}
    }
}
