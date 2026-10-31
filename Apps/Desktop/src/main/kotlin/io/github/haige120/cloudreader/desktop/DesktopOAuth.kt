package io.github.haige120.cloudreader.desktop

import java.net.ServerSocket
import java.net.InetAddress
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.awt.Desktop
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.serialization.json.*

/** User-initiated loopback authorization. Never used to create a CloudReader account. */
class DesktopOAuth(private val settings:DesktopSettings,private val secrets:DesktopSecrets){
    private val http=OkHttpClient.Builder().followRedirects(false).build()
    fun connect(provider:String){
        val clientKey=when(provider){"googleDrive"->"googleDrive.clientID";"dropbox"->"dropbox.appKey";"pcloud"->"pcloud.appKey";else->error("Unknown storage provider")}
        val client=settings.get(clientKey).trim().takeIf{it.isNotEmpty()}?:error("Save the provider's desktop OAuth client ID in Settings first.")
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
                    val values=decode(target.substringAfter('?',""))
                    if(provider=="pcloud"&&path=="/callback"&&values["access_token"]==null){
                        respond(socket,"<html><body>Finishing storage connection…<script>fetch('/finish?'+location.hash.slice(1)).then(()=>{document.body.textContent='You may return to CloudReader.'})</script></body></html>")
                        return@use
                    }
                    if(values["state"]!=state){respond(socket,"Authorization state did not match.",400);return@use}
                    values["error"]?.let{respond(socket,"Storage authorization was declined.",400);error("Storage authorization was declined.")}
                    respond(socket,"Storage authorization received. You can return to CloudReader.")
                    val tokens=if(provider=="pcloud")JsonObject(values.mapValues{JsonPrimitive(it.value)}) else{
                        val code=values["code"]?:error("The provider did not return an authorization code.")
                        val body=linkedMapOf("grant_type" to "authorization_code","code" to code,"client_id" to client,"redirect_uri" to redirect,"code_verifier" to verifier)
                        if(provider=="googleDrive")secrets.read("googleDrive.clientSecret")?.takeIf{it.isNotBlank()}?.let{body["client_secret"]=it}
                        exchange(provider,body)
                    }
                    saveTokens(provider,tokens)
                    if(provider=="pcloud"){
                        val host=values["hostname"]?:"api.pcloud.com"
                        require(host in setOf("api.pcloud.com","eapi.pcloud.com")){"Unsupported pCloud region"}
                        secrets.write("pcloud.apiHost",host)
                    }
                    settings.save(mapOf("$provider.enabled" to "true"))
                    return
                }
            }
            error("Storage authorization timed out. Try Connect again.")
        }
    }
    fun refreshGoogle(){
        val expires=secrets.read("googleDrive.expiresAt")?.toLongOrNull()?:0
        if(expires>System.currentTimeMillis()/1000+60)return
        val refresh=secrets.read("googleDrive.refreshToken")?.takeIf{it.isNotBlank()}?:error("Reconnect Google Drive in Settings.")
        val body=linkedMapOf("grant_type" to "refresh_token","refresh_token" to refresh,"client_id" to settings.get("googleDrive.clientID"))
        secrets.read("googleDrive.clientSecret")?.takeIf{it.isNotBlank()}?.let{body["client_secret"]=it}
        saveTokens("googleDrive",exchange("googleDrive",body))
    }
    private fun exchange(provider:String,values:Map<String,String>):JsonObject{
        val endpoint=if(provider=="googleDrive")"https://oauth2.googleapis.com/token" else "https://api.dropboxapi.com/oauth2/token"
        val request=Request.Builder().url(endpoint).post(form(values).toRequestBody("application/x-www-form-urlencoded".toMediaType())).build()
        return http.newCall(request).execute().use{response->
            check(response.isSuccessful){"Storage token exchange failed (HTTP ${response.code}). Check the registered client and redirect URI."}
            Json.parseToJsonElement(response.body?.string()?:error("No token response")).jsonObject
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
    private fun decode(query:String)=query.split('&').filter{it.contains('=')}.associate{URLDecoder.decode(it.substringBefore('='),"UTF-8") to URLDecoder.decode(it.substringAfter('='),"UTF-8")}
    private fun respond(socket:java.net.Socket,text:String,code:Int=200){
        val bytes=text.toByteArray();val header="HTTP/1.1 $code ${if(code==200)"OK" else "Error"}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
        socket.getOutputStream().apply{write(header.toByteArray());write(bytes);flush()}
    }
}
