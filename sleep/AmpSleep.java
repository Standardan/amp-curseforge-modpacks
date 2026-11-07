/*
 * AmpSleep - Minecraft-aware sleep supervisor for the AMP CurseForge modpack template.
 *
 * AMP starts this instead of the server. It owns the public Minecraft port and runs the real
 * server as a child process on a private port:
 *
 *   RUNNING   connections are piped straight through to the server. Logged-in players are
 *             counted; after N minutes with nobody online the server is sent "stop".
 *   SLEEPING  the server process is gone (no RAM, no CPU). The server list still shows the
 *             server (with a "sleeping" MOTD); a login attempt wakes it and the player is told
 *             to come back in a minute.
 *   STARTING  the server is booting; pings show a "waking up" MOTD, joins get the same message.
 *
 * The AMP console keeps working: everything typed is passed to the server. "stop" while asleep
 * exits cleanly, so AMP's Stop/Restart/Update behave normally. !wake, !sleep and !status are
 * handled here.
 *
 * Java 8 compatible, no dependencies. Build: javac --release 8 AmpSleep.java && jar cfe ...
 */

import java.io.*;
import java.lang.reflect.Method;
import java.net.*;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.text.SimpleDateFormat;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.regex.*;

public final class AmpSleep {
    static final String VERSION = "1.0.0";
    static final Charset LATIN1 = StandardCharsets.ISO_8859_1;
    static final Charset UTF8 = StandardCharsets.UTF_8;
    static final Pattern DONE = Pattern.compile(": Done \\([\\d.,]+s\\)! For help");

    enum State { SLEEPING, STARTING, RUNNING, STOPPING }

    // ---- settings
    int publicPort = 25565;
    String bindOverride = "";
    long idleMillis = 15 * 60_000L;
    String motdSleeping = "\u00a79\u00a7lZzz \u00a77The server is asleep.\n\u00a7fJoin to wake it up!";
    String motdStarting = "\u00a76Waking up...\n\u00a77Ready in a minute or two.";
    String kickMessage = "\u00a76The server is waking up!\n\u00a77Give it a minute or two, then join again.";
    boolean startAsleep = false;
    String mcVersion = "";
    File stateDir = new File("../tools/state");
    File propsFile = new File("server.properties");
    long stopTimeoutMillis = 180_000L;
    List<String> command = new ArrayList<>();

    // ---- runtime (guarded by lock unless volatile)
    final Object lock = new Object();
    volatile State state = State.SLEEPING;
    Process proc;
    OutputStream procIn;
    volatile String backendHost = "127.0.0.1";
    volatile int backendPort = -1;
    int players = 0;
    long idleSince = System.currentTimeMillis();
    long stopStartedAt = 0;
    boolean sleepStop = false;      // we sent "stop" to put the server to sleep
    boolean userStop = false;       // AMP/user asked the server to stop: exit when it does
    boolean wakeAfterStop = false;  // someone tried to join while it was stopping
    boolean forced = false;
    volatile String cachedStatus = null;
    volatile int lastClientProtocol = -1;
    long lastStatusRefresh = 0;
    long firstPingOkAt = 0;
    // The server is always launched from this one thread: the parent-death signal (setpriv --pdeathsig)
    // fires when the *thread* that started the child exits, so it must live as long as we do.
    final java.util.concurrent.ExecutorService launcher = java.util.concurrent.Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "launcher");
        t.setDaemon(true);
        return t;
    });
    final CountDownLatch exitLatch = new CountDownLatch(1);
    volatile int exitCode = 0;
    volatile boolean exiting = false;

    final OutputStream out = new FileOutputStream(FileDescriptor.out);
    final Object outLock = new Object();

    public static void main(String[] args) throws Exception {
        AmpSleep s = new AmpSleep();
        s.parseArgs(args);
        s.run();
    }

    void parseArgs(String[] a) {
        int i = 0;
        for (; i < a.length; i++) {
            String k = a[i];
            if (k.equals("--")) { i++; break; }
            String v = i + 1 < a.length ? a[++i] : "";
            switch (k) {
                case "--port": publicPort = Integer.parseInt(v.trim()); break;
                case "--bind": bindOverride = v.trim(); break;
                case "--idle-seconds": idleMillis = (long) (Double.parseDouble(v.trim()) * 1000); break;
                case "--motd-sleeping": if (!v.trim().isEmpty()) motdSleeping = unescape(v); break;
                case "--motd-starting": if (!v.trim().isEmpty()) motdStarting = unescape(v); break;
                case "--kick-message": if (!v.trim().isEmpty()) kickMessage = unescape(v); break;
                case "--start-asleep": startAsleep = v.trim().equalsIgnoreCase("true"); break;
                case "--mc-version": mcVersion = v.trim(); break;
                case "--state-dir": stateDir = new File(v); break;
                case "--properties": propsFile = new File(v); break;
                case "--stop-timeout": stopTimeoutMillis = Long.parseLong(v.trim()) * 1000; break;
                default: msg("Ignoring unknown option " + k);
            }
        }
        for (; i < a.length; i++) command.add(a[i]);
        if (command.isEmpty()) { msg("No server command given after --"); System.exit(2); }
    }

    // ------------------------------------------------------------------------------------------
    void run() throws Exception {
        stateDir.mkdirs();
        try {
            byte[] b = Files.readAllBytes(statusCacheFile().toPath());
            String s = new String(b, UTF8).trim();
            if (s.startsWith("{")) cachedStatus = s;
        } catch (IOException ignored) { }

        String bindHost = !bindOverride.isEmpty() ? bindOverride : readProperty("server-ip", "");
        ServerSocket listener = new ServerSocket();
        listener.setReuseAddress(true);
        try {
            listener.bind(bindHost.isEmpty() ? new InetSocketAddress(publicPort)
                                             : new InetSocketAddress(bindHost, publicPort), 64);
        } catch (IOException e) {
            msg("Could not open port " + publicPort + ": " + e.getMessage()
                + " (is another server, or an old copy of this one, still running?)");
            System.exit(1);
        }
        msg("Sleep mode on (v" + VERSION + "): listening on port " + publicPort
            + (idleMillis > 0 ? ", sleeps after " + describeMillis(idleMillis) + " with nobody online."
                              : ", idle sleep disabled."));

        Thread acceptor = new Thread(() -> acceptLoop(listener), "accept");
        acceptor.setDaemon(true);
        acceptor.start();
        Thread console = new Thread(this::consoleLoop, "console");
        console.setDaemon(true);
        console.start();
        Runtime.getRuntime().addShutdownHook(new Thread(this::onShutdownSignal, "shutdown"));

        if (startAsleep) {
            msg("Starting asleep. Join from Minecraft (or type !wake) to start the server.");
            // Matches the template's ready regex so AMP shows the instance as running.
            msg("Done (0.0s)! For help, type \"help\" - server is asleep, join to wake it");
        } else {
            wake("AMP start");
        }

        Thread ticker = new Thread(() -> {
            while (!exiting) {
                try { Thread.sleep(1000); } catch (InterruptedException e) { return; }
                try { tick(); } catch (Throwable t) { msg("tick error: " + t); }
            }
        }, "tick");
        ticker.setDaemon(true);
        ticker.start();

        exitLatch.await();
        try { listener.close(); } catch (IOException ignored) { }
        System.exit(exitCode);
    }

    void finish(int code) {
        exitCode = code;
        exiting = true;
        exitLatch.countDown();
    }

    // ------------------------------------------------------------------------------------------
    // server process
    void wake(String why) {
        synchronized (lock) {
            if (state != State.SLEEPING || exiting) return;
            try {
                String ip = readProperty("server-ip", "");
                backendHost = ip.isEmpty() || ip.equals("0.0.0.0") ? "127.0.0.1" : ip;
                backendPort = freePort(ip);
                writeProperty("server-port", Integer.toString(backendPort));
                ProcessBuilder pb = new ProcessBuilder(command);
                pb.redirectError(ProcessBuilder.Redirect.INHERIT);
                Process p;
                try {
                    p = launcher.submit(pb::start).get();
                } catch (java.util.concurrent.ExecutionException e) {
                    throw e.getCause() instanceof IOException ? (IOException) e.getCause() : new IOException(e.getCause());
                } catch (InterruptedException e) {
                    throw new IOException("interrupted");
                }
                proc = p;
                procIn = p.getOutputStream();
                state = State.STARTING;
                players = 0;
                sleepStop = false;
                userStop = false;
                wakeAfterStop = false;
                forced = false;
                firstPingOkAt = 0;
                lastStatusRefresh = System.currentTimeMillis();
                writeChildPid(p);
                msg("Starting the server (" + why + ").");
                Thread pump = new Thread(() -> pumpOutput(p), "server-output");
                pump.setDaemon(true);
                pump.start();
                Thread waiter = new Thread(() -> {
                    int code;
                    while (true) {
                        try { code = p.waitFor(); break; } catch (InterruptedException ignored) { }
                    }
                    try { pump.join(2000); } catch (InterruptedException ignored) { }
                    onServerExit(p, code);
                }, "server-wait");
                waiter.setDaemon(true);
                waiter.start();
            } catch (IOException e) {
                msg("Could not start the server: " + e.getMessage());
                finish(1);
            }
        }
    }

    void onServerExit(Process p, int code) {
        boolean wakeAgain = false;
        synchronized (lock) {
            if (proc != p) return;
            proc = null;
            procIn = null;
            players = 0;
            clearChildPid();
            if (exiting) return;
            if (sleepStop && !userStop) {
                state = State.SLEEPING;
                sleepStop = false;
                if (wakeAfterStop) {
                    wakeAgain = true;
                } else {
                    msg("Server stopped - now sleeping. It wakes up when someone joins from Minecraft (or type !wake).");
                }
            } else {
                state = State.SLEEPING;
                if (!userStop && code != 0) msg("The server exited with code " + code + ".");
                finish(code);
                return;
            }
        }
        if (wakeAgain) wake("a player tried to join while it was stopping");
    }

    void markReady(String how) {
        synchronized (lock) {
            if (state != State.STARTING) return;
            state = State.RUNNING;
            idleSince = System.currentTimeMillis();
            lastStatusRefresh = 0;
            if (idleMillis > 0)
                msg("Server is up (" + how + "). It goes to sleep after " + describeMillis(idleMillis) + " with nobody online.");
        }
    }

    void beginSleep(String why) {
        synchronized (lock) {
            if (state != State.RUNNING || proc == null) return;
            state = State.STOPPING;
            sleepStop = true;
            stopStartedAt = System.currentTimeMillis();
            msg(why + " - stopping the server to save resources.");
            sendToServer("stop");
        }
    }

    boolean sendToServer(String line) {
        OutputStream os;
        synchronized (lock) { os = procIn; }
        if (os == null) return false;
        try {
            os.write((line + "\n").getBytes(UTF8));
            os.flush();
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    void tick() {
        long now = System.currentTimeMillis();
        boolean refresh = false;
        Process kill = null;
        boolean killHard = false;
        synchronized (lock) {
            if (state == State.RUNNING && now - lastStatusRefresh > 60_000) { refresh = true; lastStatusRefresh = now; }
            if (state == State.STARTING && now - lastStatusRefresh > 10_000) { refresh = true; lastStatusRefresh = now; }
            if (state == State.STOPPING && proc != null) {
                long waited = now - stopStartedAt;
                if (waited > stopTimeoutMillis + 30_000) { kill = proc; killHard = true; }
                else if (waited > stopTimeoutMillis && !forced) { kill = proc; forced = true; }
            }
            if (state == State.RUNNING && idleMillis > 0 && players == 0 && now - idleSince >= idleMillis) {
                beginSleep("Nobody online for " + describeMillis(idleMillis));
            }
        }
        if (kill != null) {
            if (killHard) { msg("Server still running - killing it."); kill.destroyForcibly(); }
            else { msg("Server did not stop within " + (stopTimeoutMillis / 1000) + "s - terminating it."); kill.destroy(); }
        }
        if (refresh) {
            String s = fetchStatus(backendHost, backendPort);
            if (s != null) {
                cachedStatus = s;
                try { Files.write(statusCacheFile().toPath(), s.getBytes(UTF8)); } catch (IOException ignored) { }
                if (state == State.STARTING) {
                    // Fallback for packs whose "Done" line looks different: the server has answered pings
                    // for a while. (Loaders bind the port before the world has finished loading.)
                    if (firstPingOkAt == 0) firstPingOkAt = now;
                    else if (now - firstPingOkAt > 90_000) markReady("server answers pings");
                }
            }
        }
    }

    void pumpOutput(Process p) {
        byte[] buf = new byte[8192];
        StringBuilder line = new StringBuilder();
        try (InputStream in = p.getInputStream()) {
            int n;
            while ((n = in.read(buf)) > 0) {
                synchronized (outLock) {
                    out.write(buf, 0, n);
                    out.flush();
                }
                if (state != State.STARTING) { line.setLength(0); continue; }
                for (int i = 0; i < n; i++) {
                    char c = (char) (buf[i] & 0xff);
                    if (c == '\n') {
                        if (DONE.matcher(line).find()) markReady("ready message seen");
                        line.setLength(0);
                    } else if (line.length() < 8192) {
                        line.append(c);
                    }
                }
            }
        } catch (IOException ignored) { }
    }

    void onShutdownSignal() {
        if (exiting) return;   // normal exit
        exiting = true;
        Process p;
        synchronized (lock) { p = proc; userStop = true; }
        if (p == null || !p.isAlive()) return;
        msg("Received a shutdown signal - stopping the server.");
        sendToServer("stop");
        try {
            long deadline = System.currentTimeMillis() + Math.min(stopTimeoutMillis, 110_000L);
            while (p.isAlive() && System.currentTimeMillis() < deadline) Thread.sleep(250);
            if (p.isAlive()) { p.destroy(); Thread.sleep(5000); }
            if (p.isAlive()) p.destroyForcibly();
        } catch (InterruptedException ignored) { }
        clearChildPid();
    }

    // ------------------------------------------------------------------------------------------
    // AMP console
    void consoleLoop() {
        try {
            BufferedReader r = new BufferedReader(new InputStreamReader(System.in, UTF8));
            String line;
            while ((line = r.readLine()) != null) handleConsole(line);
        } catch (IOException ignored) { }
    }

    void handleConsole(String raw) {
        String line = raw.trim();
        String cmd = line.toLowerCase(Locale.ROOT);
        if (cmd.startsWith("/")) cmd = cmd.substring(1);
        switch (cmd) {
            case "!wake":
                if (state == State.SLEEPING) wake("!wake");
                else msg("The server is already " + state.name().toLowerCase(Locale.ROOT) + ".");
                return;
            case "!sleep":
                synchronized (lock) {
                    if (state != State.RUNNING) { msg("Can only sleep a running server (it is " + state.name().toLowerCase(Locale.ROOT) + ")."); return; }
                    if (players > 0) { msg(players + " player(s) online - not going to sleep."); return; }
                }
                beginSleep("!sleep");
                return;
            case "!status":
                synchronized (lock) {
                    String s = "State: " + state.name().toLowerCase(Locale.ROOT) + ", players online: " + players;
                    if (state == State.RUNNING && players == 0 && idleMillis > 0) {
                        long left = Math.max(0, idleMillis - (System.currentTimeMillis() - idleSince));
                        s += ", sleeping in " + describeMillis(left);
                    }
                    msg(s + ".");
                }
                return;
            default:
        }
        synchronized (lock) {
            if (proc != null) {
                if (cmd.equals("stop") || cmd.equals("end")) userStop = true;
                if (state == State.STOPPING && userStop && (cmd.equals("stop") || cmd.equals("end"))) {
                    msg("The server is already stopping; AMP will see it exit.");
                    return;
                }
            }
        }
        if (state != State.SLEEPING) {
            if (!sendToServer(raw)) msg("Could not send the command to the server.");
            return;
        }
        if (cmd.equals("stop") || cmd.equals("end")) {
            msg("Stopping (the server was asleep).");
            finish(0);
            return;
        }
        if (!line.isEmpty())
            msg("The server is asleep, so '" + line + "' was not run. Type !wake to start it.");
    }

    // ------------------------------------------------------------------------------------------
    // network
    void acceptLoop(ServerSocket listener) {
        while (!exiting) {
            try {
                Socket s = listener.accept();
                Thread t = new Thread(() -> handleClient(s), "client");
                t.setDaemon(true);
                t.start();
            } catch (IOException e) {
                if (exiting) return;
            }
        }
    }

    void handleClient(Socket client) {
        try {
            client.setTcpNoDelay(true);
            client.setSoTimeout(15_000);
            DataInputStream in = new DataInputStream(client.getInputStream());
            OutputStream cout = client.getOutputStream();
            int first = in.read();
            if (first < 0) { client.close(); return; }
            if (first == 0xFE) { // pre-1.7 server list ping
                if (state == State.RUNNING) pipe(client, new byte[] { (byte) 0xFE }, false);
                else client.close();
                return;
            }
            int len = readVarInt(in, first);
            if (len <= 0 || len > 32767) { client.close(); return; }
            byte[] body = new byte[len];
            in.readFully(body);
            DataInputStream hs = new DataInputStream(new ByteArrayInputStream(body));
            if (readVarInt(hs, hs.read()) != 0) { client.close(); return; }
            int protocol = readVarInt(hs, hs.read());
            readString(hs);
            hs.readUnsignedShort();
            int next = readVarInt(hs, hs.read());
            if (protocol > 0) lastClientProtocol = protocol;

            ByteArrayOutputStream raw = new ByteArrayOutputStream();
            writeVarInt(raw, len);
            raw.write(body);
            if (state == State.RUNNING && pipe(client, raw.toByteArray(), next == 2 || next == 3)) return;

            boolean starting = state != State.SLEEPING;
            if (next == 1) {
                // status request, then ping
                readPacket(in);
                writePacket(cout, 0, stringBytes(statusJson(protocol, starting ? motdStarting : motdSleeping)));
                try {
                    byte[] ping = readPacket(in);
                    if (ping.length >= 9) {
                        ByteArrayOutputStream pong = new ByteArrayOutputStream();
                        pong.write(ping, 1, 8);
                        writePacket(cout, 1, pong.toByteArray());
                    }
                } catch (IOException ignored) { }
            } else if (next == 2 || next == 3) {
                String name = "";
                try {
                    DataInputStream ls = new DataInputStream(new ByteArrayInputStream(readPacket(in)));
                    readVarInt(ls, ls.read());
                    name = readString(ls);
                } catch (IOException ignored) { }
                String reply;
                if (!mayWake(name)) {
                    reply = "You are not white-listed on this server!";
                    msg("Ignored a join from " + (name.isEmpty() ? "an unknown player" : name) + " (not on the whitelist).");
                } else {
                    reply = kickMessage;
                    if (state == State.SLEEPING) {
                        msg((name.isEmpty() ? "Someone" : name) + " is joining - waking the server up.");
                        wake((name.isEmpty() ? "someone" : name) + " joined");
                    } else if (state == State.STOPPING) {
                        synchronized (lock) { wakeAfterStop = true; }
                        msg((name.isEmpty() ? "Someone" : name) + " tried to join while it was stopping - it will start again right away.");
                    }
                }
                Map<String, Object> text = new LinkedHashMap<>();
                text.put("text", reply);
                writePacket(cout, 0, stringBytes(Json.write(text)));
            }
            cout.flush();
            client.close();
        } catch (IOException e) {
            try { client.close(); } catch (IOException ignored) { }
        }
    }

    /** Connects the client to the real server. Returns false if the server is not reachable. */
    boolean pipe(Socket client, byte[] already, boolean isPlayer) {
        Socket server = new Socket();
        try {
            server.setTcpNoDelay(true);
            server.connect(new InetSocketAddress(backendHost, backendPort), 3000);
            server.getOutputStream().write(already);
            server.getOutputStream().flush();
        } catch (IOException e) {
            try { server.close(); } catch (IOException ignored) { }
            return false;
        }
        if (isPlayer) synchronized (lock) { players++; }
        try {
            client.setSoTimeout(0);
            Thread back = new Thread(() -> copy(server, client), "server->client");
            back.setDaemon(true);
            back.start();
            copy(client, server);
            back.join();
        } catch (Exception ignored) {
        } finally {
            closeQuietly(server);
            closeQuietly(client);
            if (isPlayer) synchronized (lock) {
                players = Math.max(0, players - 1);
                if (players == 0) idleSince = System.currentTimeMillis();
            }
        }
        return true;
    }

    static void copy(Socket from, Socket to) {
        byte[] buf = new byte[16384];
        try {
            InputStream in = from.getInputStream();
            OutputStream os = to.getOutputStream();
            int n;
            while ((n = in.read(buf)) > 0) { os.write(buf, 0, n); os.flush(); }
        } catch (IOException ignored) {
        } finally {
            closeQuietly(from);
            closeQuietly(to);
        }
    }

    static void closeQuietly(Socket s) { try { s.close(); } catch (IOException ignored) { } }

    String fetchStatus(String host, int port) {
        if (port <= 0) return null;
        try (Socket s = new Socket()) {
            s.connect(new InetSocketAddress(host, port), 2000);
            s.setSoTimeout(4000);
            ByteArrayOutputStream hs = new ByteArrayOutputStream();
            writeVarInt(hs, lastClientProtocol > 0 ? lastClientProtocol : 767);
            byte[] h = host.getBytes(UTF8);
            writeVarInt(hs, h.length);
            hs.write(h);
            hs.write((port >> 8) & 0xff);
            hs.write(port & 0xff);
            writeVarInt(hs, 1);
            OutputStream os = s.getOutputStream();
            writePacket(os, 0, hs.toByteArray());
            writePacket(os, 0, new byte[0]);
            os.flush();
            DataInputStream in = new DataInputStream(s.getInputStream());
            DataInputStream p = new DataInputStream(new ByteArrayInputStream(readPacket(in)));
            if (readVarInt(p, p.read()) != 0) return null;
            String json = readString(p);
            return json.trim().startsWith("{") ? json : null;
        } catch (IOException | RuntimeException e) {
            return null;
        }
    }

    @SuppressWarnings("unchecked")
    String statusJson(int clientProtocol, String motd) {
        Map<String, Object> root = null;
        String cached = cachedStatus;
        if (cached != null) {
            try {
                Object o = Json.parse(cached);
                if (o instanceof Map) root = (Map<String, Object>) o;
            } catch (RuntimeException ignored) { }
        }
        if (root == null) root = new LinkedHashMap<>();
        if (!(root.get("version") instanceof Map)) {
            Map<String, Object> v = new LinkedHashMap<>();
            v.put("name", mcVersion.isEmpty() ? "Sleeping" : mcVersion);
            v.put("protocol", new Json.Num(Integer.toString(clientProtocol)));
            root.put("version", v);
        }
        Map<String, Object> desc = new LinkedHashMap<>();
        desc.put("text", motd);
        root.put("description", desc);
        Map<String, Object> pl = new LinkedHashMap<>();
        Object oldPlayers = root.get("players");
        Object max = oldPlayers instanceof Map ? ((Map<String, Object>) oldPlayers).get("max") : null;
        if (max == null) {
            String m = readProperty("max-players", "20").trim();
            max = new Json.Num(m.matches("\\d+") ? m : "20");
        }
        pl.put("max", max);
        pl.put("online", new Json.Num("0"));
        root.put("players", pl);
        if (!root.containsKey("favicon")) {
            File icon = new File(propsFile.getAbsoluteFile().getParentFile(), "server-icon.png");
            if (icon.isFile() && icon.length() < 64 * 1024) {
                try {
                    root.put("favicon", "data:image/png;base64," + Base64.getEncoder().encodeToString(Files.readAllBytes(icon.toPath())));
                } catch (IOException ignored) { }
            }
        }
        return Json.write(root);
    }

    boolean mayWake(String name) {
        if (!readProperty("white-list", "false").trim().equalsIgnoreCase("true")) return true;
        if (name.isEmpty()) return false;
        File dir = propsFile.getAbsoluteFile().getParentFile();
        Pattern p = Pattern.compile("\"name\"\\s*:\\s*\"([^\"]+)\"");
        for (String f : new String[] { "whitelist.json", "ops.json" }) {
            try {
                Matcher m = p.matcher(new String(Files.readAllBytes(new File(dir, f).toPath()), UTF8));
                while (m.find()) if (m.group(1).equalsIgnoreCase(name)) return true;
            } catch (IOException ignored) { }
        }
        return false;
    }

    // ------------------------------------------------------------------------------------------
    // Minecraft protocol helpers
    static int readVarInt(DataInputStream in, int first) throws IOException {
        int value = 0, pos = 0, b = first;
        while (true) {
            if (b < 0) throw new EOFException();
            value |= (b & 0x7f) << pos;
            if ((b & 0x80) == 0) return value;
            pos += 7;
            if (pos >= 35) throw new IOException("VarInt too big");
            b = in.read();
        }
    }

    static void writeVarInt(OutputStream os, int v) throws IOException {
        while (true) {
            if ((v & ~0x7f) == 0) { os.write(v); return; }
            os.write((v & 0x7f) | 0x80);
            v >>>= 7;
        }
    }

    static String readString(DataInputStream in) throws IOException {
        int n = readVarInt(in, in.read());
        if (n < 0 || n > 262144) throw new IOException("bad string length");
        byte[] b = new byte[n];
        in.readFully(b);
        return new String(b, UTF8);
    }

    static byte[] stringBytes(String s) throws IOException {
        byte[] b = s.getBytes(UTF8);
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        writeVarInt(o, b.length);
        o.write(b);
        return o.toByteArray();
    }

    static byte[] readPacket(DataInputStream in) throws IOException {
        int len = readVarInt(in, in.read());
        if (len <= 0 || len > 2_097_152) throw new IOException("bad packet length");
        byte[] b = new byte[len];
        in.readFully(b);
        return b;
    }

    static void writePacket(OutputStream os, int id, byte[] data) throws IOException {
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        writeVarInt(body, id);
        body.write(data);
        ByteArrayOutputStream pkt = new ByteArrayOutputStream();
        writeVarInt(pkt, body.size());
        body.writeTo(pkt);
        os.write(pkt.toByteArray());
        os.flush();
    }

    // ------------------------------------------------------------------------------------------
    // files
    File statusCacheFile() { return new File(stateDir, "sleep-status.json"); }
    File childPidFile() { return new File(stateDir, "server-child.pid"); }

    void writeChildPid(Process p) {
        try {
            Method m = Process.class.getMethod("pid");   // Java 9+
            Object pid = m.invoke(p);
            Files.write(childPidFile().toPath(), (pid + "\n").getBytes(UTF8));
        } catch (Exception ignored) { }
    }

    void clearChildPid() { childPidFile().delete(); }

    String readProperty(String key, String def) {
        try {
            for (String l : new String(Files.readAllBytes(propsFile.toPath()), LATIN1).split("\r?\n")) {
                if (l.startsWith(key + "=")) return l.substring(key.length() + 1);
            }
        } catch (IOException ignored) { }
        return def;
    }

    void writeProperty(String key, String value) throws IOException {
        String text = "";
        try { text = new String(Files.readAllBytes(propsFile.toPath()), LATIN1); } catch (NoSuchFileException ignored) { }
        String nl = text.contains("\r\n") ? "\r\n" : "\n";
        String[] lines = text.split("\r?\n", -1);
        boolean found = false;
        for (int i = 0; i < lines.length; i++) {
            if (lines[i].startsWith(key + "=")) { lines[i] = key + "=" + value; found = true; }
        }
        String result = String.join(nl, lines);
        if (!found) result = (result.isEmpty() || result.endsWith(nl) ? result : result + nl) + key + "=" + value + nl;
        Files.write(propsFile.toPath(), result.getBytes(LATIN1));
    }

    static int freePort(String ip) throws IOException {
        try (ServerSocket s = new ServerSocket()) {
            s.setReuseAddress(false);
            s.bind(ip.isEmpty() ? new InetSocketAddress(0) : new InetSocketAddress(ip, 0));
            return s.getLocalPort();
        }
    }

    // ------------------------------------------------------------------------------------------
    void msg(String text) {
        String line = "[" + new SimpleDateFormat("HH:mm:ss").format(new Date()) + "] [AMP Sleep]: " + text + "\n";
        synchronized (outLock) {
            try { out.write(line.getBytes(UTF8)); out.flush(); } catch (IOException ignored) { }
        }
    }

    static String describeMillis(long ms) {
        long s = (ms + 999) / 1000;
        if (s < 120) return s + " seconds";
        long m = (s + 30) / 60;
        return m + " minutes";
    }

    /** Decodes server.properties-style escapes (\u00A7, \n, \\ ...) as written by the MOTD Workbench. */
    static String unescape(String s) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c != '\\' || i + 1 >= s.length()) { sb.append(c); continue; }
            char n = s.charAt(++i);
            switch (n) {
                case 'n': sb.append('\n'); break;
                case 't': sb.append('\t'); break;
                case 'r': break;
                case 'u':
                    if (i + 4 < s.length() && s.substring(i + 1, i + 5).matches("[0-9a-fA-F]{4}")) {
                        sb.append((char) Integer.parseInt(s.substring(i + 1, i + 5), 16));
                        i += 4;
                    } else sb.append("\\u");
                    break;
                default: sb.append(n);
            }
        }
        return sb.toString();
    }

    // ------------------------------------------------------------------------------------------
    /** Minimal JSON reader/writer, enough to edit a server status response. */
    static final class Json {
        static final class Num {
            final String raw;
            Num(String raw) { this.raw = raw; }
            public String toString() { return raw; }
        }

        final String s;
        int i;
        Json(String s) { this.s = s; }

        static Object parse(String s) {
            Json j = new Json(s);
            Object v = j.value();
            j.ws();
            if (j.i != s.length()) throw new IllegalArgumentException("trailing data");
            return v;
        }

        void ws() { while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++; }

        Object value() {
            ws();
            if (i >= s.length()) throw new IllegalArgumentException("eof");
            char c = s.charAt(i);
            if (c == '{') {
                i++;
                Map<String, Object> m = new LinkedHashMap<>();
                ws();
                if (s.charAt(i) == '}') { i++; return m; }
                while (true) {
                    ws();
                    String k = str();
                    ws();
                    expect(':');
                    m.put(k, value());
                    ws();
                    if (s.charAt(i) == ',') { i++; continue; }
                    expect('}');
                    return m;
                }
            }
            if (c == '[') {
                i++;
                List<Object> l = new ArrayList<>();
                ws();
                if (s.charAt(i) == ']') { i++; return l; }
                while (true) {
                    l.add(value());
                    ws();
                    if (s.charAt(i) == ',') { i++; continue; }
                    expect(']');
                    return l;
                }
            }
            if (c == '"') return str();
            if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
            if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
            if (s.startsWith("null", i)) { i += 4; return null; }
            int st = i;
            while (i < s.length() && "+-0123456789.eE".indexOf(s.charAt(i)) >= 0) i++;
            if (st == i) throw new IllegalArgumentException("bad value at " + i);
            return new Num(s.substring(st, i));
        }

        void expect(char c) {
            if (i >= s.length() || s.charAt(i) != c) throw new IllegalArgumentException("expected " + c + " at " + i);
            i++;
        }

        String str() {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (true) {
                char c = s.charAt(i++);
                if (c == '"') return sb.toString();
                if (c != '\\') { sb.append(c); continue; }
                char e = s.charAt(i++);
                switch (e) {
                    case 'n': sb.append('\n'); break;
                    case 't': sb.append('\t'); break;
                    case 'r': sb.append('\r'); break;
                    case 'b': sb.append('\b'); break;
                    case 'f': sb.append('\f'); break;
                    case 'u': sb.append((char) Integer.parseInt(s.substring(i, i + 4), 16)); i += 4; break;
                    default: sb.append(e);
                }
            }
        }

        static String write(Object o) {
            StringBuilder sb = new StringBuilder();
            write(sb, o);
            return sb.toString();
        }

        @SuppressWarnings("unchecked")
        static void write(StringBuilder sb, Object o) {
            if (o == null) sb.append("null");
            else if (o instanceof String) quote(sb, (String) o);
            else if (o instanceof Boolean || o instanceof Num) sb.append(o);
            else if (o instanceof Map) {
                sb.append('{');
                boolean first = true;
                for (Map.Entry<String, Object> e : ((Map<String, Object>) o).entrySet()) {
                    if (!first) sb.append(',');
                    first = false;
                    quote(sb, e.getKey());
                    sb.append(':');
                    write(sb, e.getValue());
                }
                sb.append('}');
            } else if (o instanceof List) {
                sb.append('[');
                boolean first = true;
                for (Object v : (List<Object>) o) {
                    if (!first) sb.append(',');
                    first = false;
                    write(sb, v);
                }
                sb.append(']');
            } else quote(sb, o.toString());
        }

        static void quote(StringBuilder sb, String s) {
            sb.append('"');
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                    case '"': sb.append("\\\""); break;
                    case '\\': sb.append("\\\\"); break;
                    case '\n': sb.append("\\n"); break;
                    case '\r': sb.append("\\r"); break;
                    case '\t': sb.append("\\t"); break;
                    default:
                        if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                        else sb.append(c);
                }
            }
            sb.append('"');
        }
    }
}
