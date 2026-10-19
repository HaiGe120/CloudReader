package io.github.haige120.cloudreader;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.FileNotFoundException;
import java.io.OutputStream;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public final class TestDocumentProvider extends ContentProvider {
    private static final Map<String, byte[]> FIXTURES = new ConcurrentHashMap<>();

    public static void register(String name, byte[] bytes) { FIXTURES.put(name, bytes.clone()); }
    public static byte[] fixture(String name) {
        byte[] bytes = FIXTURES.get(name);
        return bytes == null ? null : bytes.clone();
    }
    public static void clear() { FIXTURES.clear(); }

    @Override public boolean onCreate() { return true; }

    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        String[] columns = projection == null ? new String[] { OpenableColumns.DISPLAY_NAME } : projection;
        String name = uri.getQueryParameter("name");
        if (name == null) throw new IllegalArgumentException("Missing test display name");
        MatrixCursor cursor = new MatrixCursor(columns);
        Object[] row = new Object[columns.length];
        for (int index = 0; index < columns.length; index++) {
            if (OpenableColumns.DISPLAY_NAME.equals(columns[index])) row[index] = name;
        }
        cursor.addRow(row);
        return cursor;
    }

    @Override public String getType(Uri uri) { return "text/plain"; }

    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new IllegalArgumentException("Read only");
        byte[] bytes = FIXTURES.get(uri.getLastPathSegment());
        if (bytes == null) throw new FileNotFoundException("Missing test fixture for " + uri);
        try {
            ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
            new Thread(() -> {
                try (OutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                    output.write(bytes);
                } catch (Exception ignored) { }
            }, "test-document-source").start();
            return pipe[0];
        } catch (Exception error) {
            FileNotFoundException wrapped = new FileNotFoundException(error.getMessage());
            wrapped.initCause(error);
            throw wrapped;
        }
    }

    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException("Read only test provider"); }
    @Override public int delete(Uri uri, String selection, String[] selectionArgs) { throw new UnsupportedOperationException("Read only test provider"); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) { throw new UnsupportedOperationException("Read only test provider"); }
}
