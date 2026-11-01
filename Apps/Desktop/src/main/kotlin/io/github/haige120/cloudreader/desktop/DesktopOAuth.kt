package io.github.haige120.cloudreader.desktop

import java.net.ServerSocket
import java.net.InetAddress
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.Properties
import java.io.InputStream
import java.awt.Desktop
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.serialization.json.*

/** Public Desktop app registration supplied by the maintainer, never a Web client secret. */
data class DesktopGoogleClient(val clientId:String="",val clientSecret:String=""){
    override fun toString()="DesktopGoogleClient([redacted])"

    companion object{
        fun bundled():DesktopGoogleClient=fromProperties(
            DesktopGoogleClient::class.java.getResourceAsStream("/cloudreader-google-oauth.properties")
        )

        internal fun fromProperties(input:InputStream?):DesktopGoogleClient=runCatching{
            val values=Properties()
            input?.use{values.load(it)}
            DesktopGoogleClient(values.getProperty("clientID","").trim(),values.getProperty("clientSecret","").trim())
        }.getOrDefault(DesktopGoogleClient())
    }
}

/** User-initiated loopback authorization. Never used to create a CloudReader account. */
class DesktopOAuth(
    private val settings:DesktopSettings,
    private val secrets:DesktopSecrets,
    private val http:OkHttpClient=OkHttpClient.Builder().followRedirects(false).build(),
    private val defaults:DesktopGoogleClient=DesktopGoogleClient.bundled(),
){
    /** An absent mode preserves legacy grants by inferring custom mode from the saved client ID. */
    fun useCustomGoogleCredentials():Boolean=synchronized(settings){
        settings.get(GOOGLE_CUSTOM_MODE).toBooleanStrictOrNull()?:settings.get(GOOGLE_CLIENT_ID).isNotBlank()
    }

    /** Persist the user's choice, retaining advanced credentials across switches. */
    fun setGoogleConnectionMode(useCustom:Boolean):Boolean=synchronized(settings){
        synchronized(secrets){
            val changed=useCustom!=useCustomGoogleCredentials()
            val updates=mutableMapOf(GOOGLE_CUSTOM_MODE to useCustom.toString())
            if(changed)updates["googleDrive.enabled"]="false"
            persistGoogleChange(updates,invalidateTokens=changed)
            changed
        }
    }

    /**
     * Blank secret retains the saved secret only for the same client. Clearing both fields resets
     * custom Google credentials without switching mode. Call only while custom mode is selected.
     * The caller must exclude these credentials from its general settings/password writes
     * and keep googleDrive.enabled false when this returns true, until Connect succeeds.
     * A suffix check cannot identify the Google client type or verify an ID/secret pair locally.
     */
    fun saveGoogleCredentials(clientId:String,enteredSecret:String):Boolean=synchronized(settings){
        synchronized(secrets) credentials@{
            check(useCustomGoogleCredentials()){"Select custom Google credentials in advanced settings before saving them."}
            val client=clientId.trim()
            val entered=enteredSecret.trim()
            require(client.isNotEmpty()||entered.isEmpty()){
                "Enter the Google Desktop app client ID with its matching secret, or clear both fields to reset Google Drive."
            }
            if(client.isNotEmpty())validateGoogleClient(client)
            val previousClient=settings.get(GOOGLE_CLIENT_ID)
            val previousSecret=secrets.read(GOOGLE_CLIENT_SECRET).orEmpty()
            val secret=when{
                client.isEmpty()->""
                entered.isNotEmpty()->entered
                else->{
                    require(client==previousClient.trim()){
                        "Changing the Google Desktop app client ID requires entering that client's matching secret. $GOOGLE_CUSTOM_SETUP"
                    }
                    previousSecret
                }
            }
            val changed=client!=previousClient.trim()||secret!=previousSecret
            if(!changed&&client==previousClient)return@credentials false

            // Freeze an inferred legacy custom mode before clearing/changing its saved client ID.
            val updates=if(changed)mapOf(GOOGLE_CLIENT_ID to client,GOOGLE_CUSTOM_MODE to "true","googleDrive.enabled" to "false")
                else mapOf(GOOGLE_CLIENT_ID to client)
            persistGoogleChange(updates,secret.takeIf{it!=previousSecret},changed)
            changed
        }
    }

    /** Caller holds both settings and secrets locks. No other provider keys are written. */
    private fun persistGoogleChange(updates:Map<String,String>,clientSecret:String?=null,invalidateTokens:Boolean){
        val previousSettings=updates.keys.associateWith{settings.get(it)}
        val secretKeys=(if(clientSecret!=null)listOf(GOOGLE_CLIENT_SECRET)else emptyList())+
            (if(invalidateTokens)GOOGLE_TOKEN_KEYS else emptyList())
        val previousSecrets=secretKeys.associateWith{secrets.read(it).orEmpty()}
        val touchedSecrets=mutableListOf<String>()
        try{
            if(clientSecret!=null){
                touchedSecrets+=GOOGLE_CLIENT_SECRET
                secrets.write(GOOGLE_CLIENT_SECRET,clientSecret)
            }
            settings.save(updates)
            if(invalidateTokens)GOOGLE_TOKEN_KEYS.forEach{key->
                touchedSecrets+=key
                // DesktopSecrets has no delete operation; empty values invalidate the old tokens.
                secrets.write(key,"")
            }
        }catch(_:Exception){
            var restored=true
            touchedSecrets.asReversed().forEach{key->
                if(runCatching{secrets.write(key,previousSecrets.getValue(key))}.isFailure)restored=false
            }
            // DesktopSettings mutates memory before persisting. A failed rollback save still
            // restores the old in-memory fields, but cannot guarantee durable recovery.
            if(runCatching{settings.save(previousSettings)}.isFailure)restored=false
            error(if(restored)"Could not save Google sign-in settings. Previous values were restored. Check local settings and credential storage, then retry."
                else "Could not save Google sign-in settings or fully persist the rollback. Check local settings and credential storage before reconnecting.")
        }
    }

    internal data class GoogleConnection(val client:DesktopGoogleClient,val useCustom:Boolean)

    private fun googleConnection():GoogleConnection=synchronized(settings){
        synchronized(secrets){
            val custom=useCustomGoogleCredentials()
            val client=if(custom)DesktopGoogleClient(settings.get(GOOGLE_CLIENT_ID).trim(),secrets.read(GOOGLE_CLIENT_SECRET).orEmpty().trim())
                else DesktopGoogleClient(defaults.clientId.trim(),defaults.clientSecret.trim())
            if(custom)validateGoogleClient(client.clientId)
            else{
                check(client.clientId.isNotBlank()){GOOGLE_NOT_CONFIGURED}
                check(validGoogleClient(client.clientId)){GOOGLE_MISCONFIGURED}
            }
            GoogleConnection(client,custom)
        }
    }

    fun connect(provider:String){
        val clientKey=when(provider){"googleDrive"->"googleDrive.clientID";"dropbox"->"dropbox.appKey";"pcloud"->"pcloud.appKey";else->error("Unknown storage provider")}
        val google=if(provider=="googleDrive")googleConnection()else null
        val client=google?.client?.clientId?:settings.get(clientKey).trim().takeIf{it.isNotEmpty()}?:error("Save the provider's desktop OAuth client ID in Settings first.")
        val state=random(32);val verifier=random(48)
        val challenge=Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
        ServerSocket(0,8,InetAddress.getByName("127.0.0.1")).use{server->
            server.soTimeout=180_000
            val redirect="http://127.0.0.1:${server.localPort}/callback"
            val params=linkedMapOf("client_id" to client,"redirect_uri" to redirect,"state" to state)
            params["response_type"]=if(provider=="pcloud")"token" else "code"
            if(provider!="pcloud"){params["code_challenge"]=challenge;params["code_challenge_method"]="S256"}
            if(provider=="googleDrive"){params["scope"]="https://www.googleapis.com/auth/drive.appdata";params["access_type"]="offline";params["prompt"]="consent"}
            if(provider=="dropbox")params["token_access_type"]="offline"
            val authorize=when(provider){"googleDrive"->"https://accounts.google.com/o/oauth2/v2/auth";"dropbox"->"https://www.dropbox.com/oauth2/authorize";else->"https://my.pcloud.com/oauth2/authorize"}
            check(Desktop.isDesktopSupported()&&Desktop.getDesktop().isSupported(Desktop.Action.BROWSE)){"A system browser is required for storage authorization."}
            Desktop.getDesktop().browse(URI(authorize+"?"+form(params)))
            val deadline=System.nanoTime()+180_000_000_000L
            while(System.nanoTime()<deadline){
                server.accept().use{socket->
                    socket.soTimeout=5000
                    val request=socket.getInputStream().bufferedReader().readLine().orEmpty()
                    val target=request.split(' ').getOrNull(1).orEmpty()
                    val path=target.substringBefore('?')
                    if(path!="/callback"&&path!="/finish"){respond(socket,"Not found",404);return@use}
                    val query=target.substringAfter('?',"")
                    val values=if(google!=null)googleCallbackValues(query)else decode(query)
                    if(provider=="pcloud"&&path=="/callback"&&values["access_token"]==null){
                        respond(socket,"<html><body>Finishing storage connection…<script>fetch('/finish?'+location.hash.slice(1)).then(()=>{document.body.textContent='You may return to CloudReader.'})</script></body></html>")
                        return@use
                    }
                    if(values["state"]!=state){respond(socket,"Authorization state did not match.",400);return@use}
                    values["error"]?.let{respond(socket,"Storage authorization was declined.",400);error(if(google!=null)googleErrorMessage(it,useCustom=google.useCustom)else "Storage authorization was declined.")}
                    respond(socket,"Storage authorization received. You can return to CloudReader.")
                    val tokens=if(provider=="pcloud")JsonObject(values.mapValues{JsonPrimitive(it.value)}) else{
                        val code=values["code"]?:error("The provider did not return an authorization code.")
                        val body=linkedMapOf("grant_type" to "authorization_code","code" to code,"client_id" to client,"redirect_uri" to redirect,"code_verifier" to verifier)
                        google?.client?.clientSecret?.takeIf{it.isNotBlank()}?.let{body["client_secret"]=it}
                        exchange(provider,body,google?.useCustom==true)
                    }
                    if(google!=null)saveGoogleTokens(google,tokens,enable=true)else saveTokens(provider,tokens)
                    if(provider=="pcloud"){
                        val host=values["hostname"]?:"api.pcloud.com"
                        require(host in setOf("api.pcloud.com","eapi.pcloud.com")){"Unsupported pCloud region"}
                        secrets.write("pcloud.apiHost",host)
                    }
                    if(google==null)settings.save(mapOf("$provider.enabled" to "true"))
                    return
                }
            }
            error("Storage authorization timed out. Try Connect again.")
        }
    }
    fun refreshGoogle(){
        val google=googleConnection()
        val expires=secrets.read("googleDrive.expiresAt")?.toLongOrNull()?:0
        if(expires>System.currentTimeMillis()/1000+60)return
        val refresh=secrets.read("googleDrive.refreshToken")?.takeIf{it.isNotBlank()}?:error("Reconnect Google Drive in Settings.")
        val body=linkedMapOf("grant_type" to "refresh_token","refresh_token" to refresh,"client_id" to google.client.clientId)
        google.client.clientSecret.takeIf{it.isNotBlank()}?.let{body["client_secret"]=it}
        saveGoogleTokens(google,exchange("googleDrive",body,google.useCustom))
    }
    internal fun saveGoogleTokens(connection:GoogleConnection,tokens:JsonObject,enable:Boolean=false)=synchronized(settings){
        synchronized(secrets){
            check(connection==googleConnection()){"Google sign-in settings changed. Choose Connect Google Drive again."}
            if(enable&&(tokens["refresh_token"] as? JsonPrimitive)?.takeIf{it.isString}?.contentOrNull.isNullOrBlank()){
                // Account selection may have changed users. Never combine account B's
                // access token with account A's previous refresh grant.
                persistGoogleChange(mapOf("googleDrive.enabled" to "false"),invalidateTokens=true)
                error("Google did not return offline access. Choose Connect Google Drive again and approve backup access.")
            }
            saveTokens("googleDrive",tokens)
            if(enable)settings.save(mapOf("googleDrive.enabled" to "true"))
        }
    }
    private fun exchange(provider:String,values:Map<String,String>,customGoogle:Boolean=false):JsonObject{
        val endpoint=if(provider=="googleDrive")"https://oauth2.googleapis.com/token" else "https://api.dropboxapi.com/oauth2/token"
        val request=Request.Builder().url(endpoint).post(form(values).toRequestBody("application/x-www-form-urlencoded".toMediaType())).build()
        if(provider=="googleDrive")return exchangeGoogle(request,customGoogle)
        return http.newCall(request).execute().use{response->
            check(response.isSuccessful){"Storage token exchange failed (HTTP ${response.code}). Check the registered client and redirect URI."}
            Json.parseToJsonElement(response.body?.string()?:error("No token response")).jsonObject
        }
    }
    private fun exchangeGoogle(request:Request,customGoogle:Boolean):JsonObject{
        try{
            return http.newCall(request).execute().use{response->
                if(!response.isSuccessful)throw GoogleOAuthException(googleHttpErrorMessage(response.code,response.peekBody(16_384).string(),customGoogle))
                val tokens=runCatching{Json.parseToJsonElement(response.body?.string().orEmpty()) as? JsonObject}.getOrNull()
                    ?:throw GoogleOAuthException("Google Drive returned an unreadable token response. Try Connect Google Drive again.")
                // Validate shapes here so JSON parser/type exceptions cannot expose response values.
                val access=tokens["access_token"] as? JsonPrimitive
                val refresh=tokens["refresh_token"]
                val expiry=tokens["expires_in"]
                if(access?.isString!=true||access.content.isBlank()||
                    (refresh!=null&&(refresh !is JsonPrimitive||!refresh.isString||refresh.content.isBlank()))||
                    (expiry!=null&&(expiry !is JsonPrimitive||expiry.longOrNull==null||expiry.longOrNull!!<=0)))
                    throw GoogleOAuthException("Google Drive returned an incomplete token response. Try Connect Google Drive again.")
                tokens
            }
        }catch(error:GoogleOAuthException){throw error}
        catch(_:Exception){
            // Transport exceptions may contain request details. Never attach the original cause.
            throw GoogleOAuthException("Could not reach Google Drive authorization. Check your network connection and try again.")
        }
    }
    private fun saveTokens(provider:String,tokens:JsonObject){
        val access=tokens["access_token"]?.jsonPrimitive?.contentOrNull?:error("Storage provider returned no access token.")
        secrets.write("$provider.accessToken",access)
        tokens["refresh_token"]?.jsonPrimitive?.contentOrNull?.let{secrets.write("$provider.refreshToken",it)}
        val ttl=tokens["expires_in"]?.jsonPrimitive?.longOrNull?:3600
        secrets.write("$provider.expiresAt",(System.currentTimeMillis()/1000+ttl).toString())
    }
    private fun random(bytes:Int)=Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(bytes).also{SecureRandom().nextBytes(it)})
    private fun form(values:Map<String,String>)=values.entries.joinToString("&"){"${URLEncoder.encode(it.key,"UTF-8")}=${URLEncoder.encode(it.value,"UTF-8")}"}
    private fun decode(query:String)=decodeQuery(query)
    private fun respond(socket:java.net.Socket,text:String,code:Int=200){
        val bytes=text.toByteArray();val header="HTTP/1.1 $code ${if(code==200)"OK" else "Error"}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
        socket.getOutputStream().apply{write(header.toByteArray());write(bytes);flush()}
    }
    private class GoogleOAuthException(message:String):IllegalStateException(message)

    companion object{
        private const val GOOGLE_CLIENT_ID="googleDrive.clientID"
        private const val GOOGLE_CLIENT_SECRET="googleDrive.clientSecret"
        private const val GOOGLE_CUSTOM_MODE="googleDrive.useCustomCredentials"
        private val GOOGLE_TOKEN_KEYS=listOf("googleDrive.accessToken","googleDrive.refreshToken","googleDrive.expiresAt")
        private const val GOOGLE_CUSTOM_SETUP="In advanced settings, use a Google OAuth client of type Desktop app for Windows/Linux with its matching client secret. Web application and Android clients are not suitable for this desktop flow. Check the Google Drive API and consent screen/test users for that project."
        private const val GOOGLE_NOT_CONFIGURED="Google sign-in is not configured in this build. Contact the app maintainer."
        private const val GOOGLE_MISCONFIGURED="Google sign-in is misconfigured in this build. Contact the app maintainer."

        private fun validGoogleClient(client:String)=client.matches(Regex("[A-Za-z0-9][A-Za-z0-9_-]*\\.apps\\.googleusercontent\\.com"))

        private fun validateGoogleClient(client:String){
            require(validGoogleClient(client)){
                "Google Desktop app client IDs must end in .apps.googleusercontent.com. $GOOGLE_CUSTOM_SETUP"
            }
        }

        private fun decodeQuery(query:String)=query.split('&').filter{it.contains('=')}.associate{
            URLDecoder.decode(it.substringBefore('='),"UTF-8") to URLDecoder.decode(it.substringAfter('='),"UTF-8")
        }

        internal fun googleCallbackValues(query:String):Map<String,String> = try{
            decodeQuery(query)
        }catch(_:IllegalArgumentException){
            throw GoogleOAuthException("Google returned an invalid authorization callback. Try Connect Google Drive again.")
        }

        /** Only exact known codes are displayed; descriptions, bodies and unknown codes are untrusted. */
        internal fun googleHttpErrorMessage(status:Int,body:String?,useCustom:Boolean=false):String{
            val code=runCatching{
                val json=Json.parseToJsonElement(body.orEmpty()) as? JsonObject
                (json?.get("error") as? JsonPrimitive)?.takeIf{it.isString}?.content
            }.getOrNull()
            return googleErrorMessage(code,status,useCustom)
        }

        internal fun googleErrorMessage(code:String?,status:Int?=null,useCustom:Boolean=false):String{
            val setup=if(useCustom)GOOGLE_CUSTOM_SETUP else GOOGLE_MISCONFIGURED
            val recovery=when(code){
                "invalid_client"->"Google rejected the client credentials (invalid_client). $setup"
                "invalid_grant"->"Google could not use the authorization code or refresh token (invalid_grant). Choose Connect Google Drive again."+
                    if(useCustom)" If credentials changed, first save the matching Desktop app client ID and secret in advanced settings."else ""
                "access_denied"->"Google Drive access was denied or cancelled (access_denied). Choose Connect Google Drive again and grant the requested access. For a testing app, ask the project owner to add your account as a test user; managed accounts may need administrator approval."
                "redirect_uri_mismatch","unauthorized_client"->"Google rejected the desktop authorization setup ($code). $setup"
                "invalid_request","invalid_scope"->"Google rejected the authorization request ($code). $setup"
                "admin_policy_enforced","org_internal"->"Google account policy blocked authorization ($code). Ask the Google Workspace administrator or project owner to allow your account to use this Desktop app."
                "disallowed_useragent"->"Google requires a supported system browser (disallowed_useragent). Choose Connect Google Drive using your default browser."
                else->"Google Drive authorization failed. Try Connect Google Drive again. $setup"
            }
            return if(status==null)recovery else "Google Drive token exchange failed (HTTP $status). $recovery"
        }
    }
}
