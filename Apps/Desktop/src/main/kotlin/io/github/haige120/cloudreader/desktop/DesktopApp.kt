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
import io.github.haige120.cloudreader.core.assistant.AIProfile
import androidx.compose.ui.input.key.*
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
    var appAppearance by remember { mutableStateOf(settings.get("app.appearance", "System")) }
    val appDark = darkTheme ?: when (appAppearance) {
        "Light" -> false
        "Dark" -> true
        else -> isSystemInDarkTheme()
    }
    val sync=remember{DesktopSync(repository,root.resolve("recovery/merge-candidates.jsonl"))}
    var destination by rememberSaveable { mutableStateOf(initialDestination) }
    var oauthBusy by remember { mutableStateOf(false) }
    var books by remember{mutableStateOf(repository.books())}
    var chats by remember{mutableStateOf(repository.chats())}
    val shelf = remember(books) { books.map(BookRecord::portable) }
    val byId = remember(books) { books.associateBy { io.github.haige120.cloudreader.core.model.canonicalUUID(it.id.value) } }
    var nearby by remember { mutableStateOf<String?>(null) }
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
    var consentWrite by remember { mutableStateOf<Job?>(null) }
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
    fun task(scheduleSync: Boolean = true, action: suspend () -> Unit): Job = scope.launch {
        try {
            withContext(Dispatchers.IO) { action() }
            refresh()
            if (scheduleSync) changes.tryEmit(Unit)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            snackbar.showSnackbar(failure.message ?: "The operation failed.")
        }
    }
    fun open(book:BookRecord){selected=book;task{repository.opened(book.id)}}
    fun ask(book: BookRecord?, selection: String?, surrounding: String? = null) {
        requestJob?.cancel()
        val latest = book?.let { source -> chats.firstOrNull { it.bookID.equals(source.id.value, true) } }
        activeId = latest?.id
        contextBook = book
        excerpt = selection?.takeIf(String::isNotBlank)
        nearby = surrounding?.takeIf(String::isNotBlank)
        includeContext = latest?.includeBookContext ?: (book != null)
        draft = ""
        aiError = null
        destination = AppDestination.ASSISTANT
    }
    fun imports(paths:List<Path>){task{
        val results=repository.accept(paths)
        val first=results.filterIsInstance<ImportResult.Imported>().firstOrNull()?.book
        withContext(Dispatchers.Main){first?.let(::open);snackbar.showSnackbar("Imported ${results.count{it is ImportResult.Imported}} · failed ${results.count{it !is ImportResult.Imported}}")}
    }}
    fun request(chat: ChatRecord, saveQuestion: Boolean = false, source: BookRecord? = null) {
        if (requestJob?.isActive == true) return
        busy = true
        aiError = null
        requestJob = scope.launch {
            try {
                consentWrite?.join()
                val prepared = withContext(Dispatchers.IO) {
                    val result = if (chat.includeBookContext && source != null && chat.bookContext.isNullOrBlank())
                        chat.copy(bookContext = readDesktopBookContext(source)) else chat
                    if (saveQuestion) repository.saveChat(result)
                    result
                }
                if (saveQuestion) {
                    activeId = prepared.id
                    draft = ""
                    refresh()
                    changes.tryEmit(Unit)
                }
                val answer = withContext(Dispatchers.IO) {
                    val profile = settings.profile()
                    desktopAssistant(profile, settings, secrets).ask(profile, prepared.messages,
                        prepared.bookTitle.takeIf { prepared.includeBookContext },
                        prepared.selectedText.takeIf { prepared.includeBookContext },
                        prepared.bookContext.takeIf { prepared.includeBookContext })
                }
                val reply = ChatMessage(UUID.randomUUID().toString().uppercase(), "assistant", answer, nowFoundationSeconds())
                withContext(Dispatchers.IO) { repository.saveChat(prepared.copy(messages = prepared.messages + reply, modifiedAt = nowFoundationSeconds())) }
                refresh()
                changes.tryEmit(Unit)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                aiError = failure.message ?: "AI request failed"
            } finally {
                if (requestJob === coroutineContext[Job]) {
                    busy = false
                    requestJob = null
                }
            }
        }
    }
    LaunchedEffect(externalImports?.first){externalImports?.second?.takeIf{it.isNotEmpty()}?.let(::imports)}
    DisposableEffect(Unit){onDispose{requestJob?.cancel()}}
    CloudReaderTheme(darkTheme = appDark) {
        val reader=selected
        if(reader!=null){
            DesktopReader(reader,root.resolve("reader-cache"),settings,secrets,appDark,onClose={selected=null;refresh()},
                onPosition={fraction,location->task{repository.savePosition(reader.id,fraction,location)}},
                onAsk={text,surrounding->selected=null;ask(reader,text,surrounding)})
        }else CloudReaderShell(destination,{destination=it},snackbar){when(destination){
            AppDestination.LIBRARY->LibraryContent(shelf,search,favorites,syncStatus,{search=it},{favorites=!favorites},
                {imports(picker.pickBooks())},{scope.launch{synchronize(SyncTrigger.MANUAL)}},onOpen={portable->byId[portable.id]?.let(::open)},
                onAsk={portable->ask(byId[portable.id],null)},
                onFavorite={portable->task{repository.setFavorite(BookId(portable.id),!portable.isBookmarked)}},
                onRemove={portable->task{repository.remove(BookId(portable.id))}},
                cover={portable->byId[portable.id]?.let { desktopCover(it) }})
            AppDestination.ASSISTANT->{
                val active=chats.firstOrNull{it.id==activeId}
                val source = contextBook ?: active?.bookID?.let { id -> books.firstOrNull { it.id.value.equals(id, true) } }
                val fromReader = excerpt != null || nearby != null
                val selectedPassage = if (fromReader) excerpt else active?.selectedText
                val bookText = if (fromReader) nearby else active?.bookContext
                val preview = listOfNotNull(selectedPassage?.take(110), bookText?.take(125))
                    .joinToString("\n").ifBlank { source?.title ?: active?.bookTitle.orEmpty() }.ifBlank { null }
                fun send() {
                    val question = draft.trim()
                    if (busy || question.isEmpty()) return
                    val now = nowFoundationSeconds()
                    val chat = active ?: ChatRecord(UUID.randomUUID().toString().uppercase(), question.take(60),
                        bookID = source?.id?.value, bookTitle = source?.title, createdAt = now, modifiedAt = now)
                    val message = ChatMessage(UUID.randomUUID().toString().uppercase(), "user", question, now)
                    request(chat.copy(messages = chat.messages + message, selectedText = selectedPassage.takeIf { includeContext },
                        bookContext = bookText.takeIf { includeContext }, includeBookContext = includeContext, modifiedAt = now),
                        saveQuestion = true, source = source)
                }
                AssistantContent(chats,active,draft,busy,includeContext,preview,aiError,
                    "${settings.profile().name} · ${settings.profile().model.ifBlank{"Set up a model in Settings"}}",
                    {draft=it},{id->
                        requestJob?.cancel(); activeId=id; contextBook=null; excerpt=null; nearby=null; draft=""; aiError=null
                        includeContext=chats.first{it.id==id}.includeBookContext
                    },{
                        requestJob?.cancel(); contextBook=source; activeId=null; includeContext=source!=null; draft=""; aiError=null
                    },
                    {enabled ->
                        if (!busy) {
                            includeContext = enabled
                            active?.let { chat ->
                                val previous = consentWrite
                                consentWrite = task {
                                    previous?.join()
                                    repository.setChatContextConsent(chat.id, enabled)
                                }
                            }
                        }
                    },
                    onSend=::send, onCancel={requestJob?.cancel();aiError="Request stopped. You can retry."},
                    onRetry={active?.let{request(it.copy(includeBookContext=includeContext))}},
                    onDelete={active?.let{chat->requestJob?.cancel();task{repository.removeChat(chat.id);withContext(Dispatchers.Main){activeId=null;contextBook=null;excerpt=null;nearby=null;includeContext=false}}}},
                    composerModifier=Modifier.onPreviewKeyEvent { event ->
                        if (event.isCtrlPressed && event.key == Key.Enter) {
                            if (event.type == KeyEventType.KeyDown) send()
                            true
                        } else false
                    })

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
                        appAppearance=settings.get("app.appearance","System")
                        result(true,"Settings saved on this device");changes.tryEmit(Unit)
                    }catch(cancelled:CancellationException){throw cancelled}
                    catch(failure:Exception){result(false,failure.message?:"Settings could not be saved")}
                }
            })
        }}
    }
}

internal fun saveDesktopSettings(settings:DesktopSettings,secrets:DesktopSecrets,updates:Map<String,String>,passwords:Map<String,String>){
    val aiUpdates = mutableMapOf<String, String>()
    if ("ai.protocol" in updates || "ai.endpoint" in updates || !passwords["ai.apiKey"].isNullOrBlank()) {
        val previous = settings.profile()
        val next = previous.copy(protocol = updates["ai.protocol"] ?: previous.protocol, endpoint = updates["ai.endpoint"] ?: previous.endpoint)
        val origin = next.desktopOrigin()
        if (settings.get("ai.legacyKeyOrigin").isEmpty()) {
            aiUpdates["ai.legacyKeyOrigin"] = runCatching { previous.desktopOrigin() }.getOrDefault("invalid")
        }
        passwords["ai.apiKey"]?.trim()?.takeIf(String::isNotEmpty)?.let { secrets.write(originKey(origin), it) }
    }
    val google=DesktopOAuth(settings,secrets)
    val useCustom=updates["googleDrive.useCustomCredentials"]?.toBooleanStrictOrNull()?:google.useCustomGoogleCredentials()
    val modeChanged=google.setGoogleConnectionMode(useCustom)
    val credentialsChanged=if(useCustom)google.saveGoogleCredentials(updates["googleDrive.clientID"].orEmpty(),passwords["googleDrive.clientSecret"].orEmpty())else false
    val preserved=updates.filterKeys{it !in setOf("googleDrive.clientID","googleDrive.useCustomCredentials","googleDrive.enabled")}
    settings.save(preserved+aiUpdates+mapOf("googleDrive.enabled" to if(modeChanged||credentialsChanged)"false"else updates["googleDrive.enabled"].orEmpty()))
    passwords.filterKeys{it!="googleDrive.clientSecret" && it!="ai.apiKey"}.filterValues{it.isNotBlank()}.forEach{(key,value)->secrets.write(key,value)}
}

@Composable
internal fun DesktopSettingsScreen(settings:DesktopSettings,secrets:DesktopSecrets,busy:Boolean=false,
    onConnect:(String,Map<String,String>,Map<String,String>,(Boolean,String)->Unit)->Unit,
    onSave:(Map<String,String>,Map<String,String>,(Boolean,String)->Unit)->Unit){
    val fields=listOf("app.appearance","ai.webSearch","folder.path","folder.enabled","webdav.url","webdav.user","webdav.enabled","ai.name","ai.protocol","ai.model","ai.endpoint",
        "credentials.plaintext","googleDrive.clientID","googleDrive.enabled","googleDrive.useCustomCredentials","dropbox.appKey","dropbox.enabled","pcloud.appKey","pcloud.enabled",
        "sftp.enabled","sftp.host","sftp.port","sftp.username","sftp.directory","sftp.hostKey")
    var values by remember{mutableStateOf(fields.associateWith{settings.get(it,when(it){"app.appearance"->"System";"ai.name"->"My AI";"ai.protocol"->"openAIResponses";"googleDrive.useCustomCredentials"->DesktopOAuth(settings,secrets).useCustomGoogleCredentials().toString();else->""})})}
    var passwords by remember{mutableStateOf(mapOf("ai.apiKey" to "","webdav.password" to "","googleDrive.clientSecret" to "","sftp.password" to ""))}
    var browseModels by remember { mutableStateOf(false) }
    var advancedGoogle by remember{mutableStateOf(false)}
    var feedback by remember{mutableStateOf<Pair<Boolean,String>?>(null)}
    var saving by remember{mutableStateOf(false)}
    fun edit(key: String, value: String) {
        if (key in setOf("ai.endpoint", "ai.protocol") && value != values[key]) {
            passwords = passwords + ("ai.apiKey" to "")
        }
        values = values + (key to value)
    }
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
        Text("App appearance", style=MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            listOf("System","Light","Dark").forEach { mode ->
                FilterChip(selected=values["app.appearance"]==mode, onClick={edit("app.appearance",mode)}, label={Text(mode)})
            }
        }
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
        OutlinedTextField(passwords["ai.apiKey"].orEmpty(),{passwords=passwords+("ai.apiKey" to it)},label={Text("API key (blank uses the saved key for this provider)")},visualTransformation=PasswordVisualTransformation(),modifier=Modifier.fillMaxWidth())
        TextButton(onClick={browseModels=true}) { Text("Browse provider models") }
        if (browseModels) {
            val profile = AIProfile(protocol=values.getValue("ai.protocol"), endpoint=values.getValue("ai.endpoint"))
            DesktopModelPicker(profile,passwords["ai.apiKey"].orEmpty(),settings,secrets,
                onChoose={edit("ai.model",it);browseModels=false},onDismiss={browseModels=false})
        }
        Row(verticalAlignment=androidx.compose.ui.Alignment.CenterVertically) {
            Checkbox(values["ai.webSearch"]=="true",{edit("ai.webSearch",it.toString())})
            Text("Allow provider web search")
        }
        Row{Checkbox(values["credentials.plaintext"]=="true",{edit("credentials.plaintext",it.toString())});Text("Allow plaintext credential fallback on this device")}
        Text("Off by default. Enable only if no OS secret service is available and you accept credentials being readable in your local credential file. Restart after changing this option.",style=MaterialTheme.typography.bodySmall)
        Text(secrets.description,style=MaterialTheme.typography.bodySmall)
        Button(onClick={saving=true;onSave(values.toMap(),passwords.toMap()){success,message->result(success,message,clearPasswords=true)}},enabled=!busy&&!saving){Text(if(saving)"Saving…"else"Save settings")}
    }
}
