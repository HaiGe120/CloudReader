package io.github.haige120.cloudreader.desktop

import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import androidx.compose.ui.unit.dp
import java.nio.file.Path
import java.nio.file.Files

fun main(args:Array<String>){
    if(args.firstOrNull()=="--runtime-check"){
        require(args.size==2){"Supply a separate output directory for the runtime check."}
        PackagedRuntimeCheck.run(Path.of(args[1]))
        kotlin.system.exitProcess(0)
    }
    application {
    val root=Path.of(System.getenv("CLOUDREADER_DESKTOP_HOME")?:Path.of(System.getProperty("user.home"),".cloudreader-desktop").toString())
    Files.createDirectories(root.resolve("reader-cache"))
    val repository=androidx.compose.runtime.remember { FileLibraryRepository(root).also { it.seedDemo() } }
    var incoming by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<Pair<Long,List<Path>>?>(args.takeIf{it.isNotEmpty()}?.let{System.nanoTime() to it.map{value->Path.of(value)}}) }
    Window(onCloseRequest=::exitApplication,title="CloudReader",state=rememberWindowState(width=1100.dp,height=800.dp)){
        androidx.compose.runtime.DisposableEffect(window) {
            val drop=java.awt.dnd.DropTarget(window,object:java.awt.dnd.DropTargetAdapter(){
                override fun drop(event:java.awt.dnd.DropTargetDropEvent){
                    if(!event.isDataFlavorSupported(java.awt.datatransfer.DataFlavor.javaFileListFlavor)){event.rejectDrop();return}
                    event.acceptDrop(java.awt.dnd.DnDConstants.ACTION_COPY)
                    val paths=(event.transferable.getTransferData(java.awt.datatransfer.DataFlavor.javaFileListFlavor) as? List<*>)?.filterIsInstance<java.io.File>()?.map{it.toPath()}.orEmpty()
                    incoming=System.nanoTime() to paths
                    event.dropComplete(true)
                }
            })
            onDispose{drop.isActive=false;window.dropTarget=null}
        }
        CloudReaderDesktopApp(repository,SwingFilePicker(),root,incoming)
    }
}
}
