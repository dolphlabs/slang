// heavy/batch in Java: memory-mapped chunks, a platform thread per core,
// open-addressing tables with primitive keys merged at the end.
// See bench/SPEC.md.
import java.io.IOException;
import java.io.PrintStream;
import java.io.BufferedOutputStream;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;

public class Batch {
    static long mix(long x) {
        x ^= x >>> 33;
        x *= 0xff51afd7ed558ccdL;
        x ^= x >>> 33;
        x *= 0xc4ceb9fe1a85ec53L;
        return x ^ (x >>> 33);
    }

    /** long -> long, key+1 stored so 0 marks empty. */
    static final class LongMap {
        long[] keys, vals;
        int size;

        LongMap(int cap) { keys = new long[cap]; vals = new long[cap]; }

        void add(long key, long v) {
            if ((size + 1) * 2 > keys.length) grow();
            int mask = keys.length - 1;
            int i = (int) mix(key) & mask;
            long k = key + 1;
            while (keys[i] != 0 && keys[i] != k) i = (i + 1) & mask;
            if (keys[i] == 0) { keys[i] = k; size++; }
            vals[i] += v;
        }

        void grow() {
            long[] ok = keys, ov = vals;
            keys = new long[ok.length * 2];
            vals = new long[ok.length * 2];
            size = 0;
            for (int i = 0; i < ok.length; i++) if (ok[i] != 0) add(ok[i] - 1, ov[i]);
        }
    }

    /** sku (up to 16 bytes, packed into two longs plus a length) -> long. */
    static final class SkuMap {
        long[] a, b, vals;
        byte[] lens;
        int size;

        SkuMap(int cap) { a = new long[cap]; b = new long[cap]; vals = new long[cap]; lens = new byte[cap]; }

        void add(long ka, long kb, int len, long v) {
            if ((size + 1) * 2 > a.length) grow();
            int mask = a.length - 1;
            int i = (int) mix(ka * 31 + kb + len) & mask;
            while (lens[i] != 0 && (lens[i] != len || a[i] != ka || b[i] != kb)) i = (i + 1) & mask;
            if (lens[i] == 0) { a[i] = ka; b[i] = kb; lens[i] = (byte) len; size++; }
            vals[i] += v;
        }

        void grow() {
            long[] oa = a, ob = b, ov = vals;
            byte[] ol = lens;
            a = new long[oa.length * 2]; b = new long[oa.length * 2]; vals = new long[oa.length * 2]; lens = new byte[oa.length * 2];
            size = 0;
            for (int i = 0; i < oa.length; i++) if (ol[i] != 0) add(oa[i], ob[i], ol[i], ov[i]);
        }
    }

    static final class Part {
        long rows;
        final long[] regions = new long[676 * 3];
        LongMap users = new LongMap(1 << 20);
        SkuMap skus = new SkuMap(1 << 17);
    }

    static void work(FileChannel ch, long start, long end, Part p) throws IOException {
        MappedByteBuffer buf = ch.map(FileChannel.MapMode.READ_ONLY, start, end - start);
        int n = (int) (end - start), i = 0;
        while (i < n) {
            while (buf.get(i) != ',') i++;
            i++;
            long user = 0;
            byte c;
            while ((c = buf.get(i)) != ',') { user = user * 10 + (c - '0'); i++; }
            i++;
            long ka = 0, kb = 0;
            int len = 0;
            while ((c = buf.get(i)) != ',') {
                if (len < 8) ka |= (c & 0xffL) << (8 * len);
                else if (len < 16) kb |= (c & 0xffL) << (8 * (len - 8));
                len++;
                i++;
            }
            i++;
            long qty = 0;
            while ((c = buf.get(i)) != ',') { qty = qty * 10 + (c - '0'); i++; }
            i++;
            long price = 0;
            while ((c = buf.get(i)) != ',') { price = price * 10 + (c - '0'); i++; }
            i++;
            int r = ((buf.get(i) - 'A') * 26 + (buf.get(i + 1) - 'A')) * 3;
            i += 3;
            long rev = qty * price;
            p.regions[r]++;
            p.regions[r + 1] += qty;
            p.regions[r + 2] += rev;
            p.rows++;
            p.users.add(user, rev);
            p.skus.add(ka, kb, Math.min(len, 16), rev);
        }
    }

    static String sku(long a, long b, int len) {
        StringBuilder s = new StringBuilder(len);
        for (int i = 0; i < len; i++) s.append((char) (i < 8 ? (a >>> (8 * i)) & 0xff : (b >>> (8 * (i - 8))) & 0xff));
        return s.toString();
    }

    public static void main(String[] args) throws Exception {
        Path path = Path.of(args[0]);
        try (FileChannel ch = FileChannel.open(path, StandardOpenOption.READ)) {
            long size = ch.size();
            int workers = Integer.parseInt(System.getenv().getOrDefault("WORKERS",
                    String.valueOf(Runtime.getRuntime().availableProcessors())));
            // a mapping is limited to 2GB: at least one chunk per GB
            int chunks = (int) Math.max(workers, size / (1L << 30) + 1);
            chunks = (int) Math.min(chunks, size / 65536 + 1);
            long[] bounds = new long[chunks + 1];
            java.nio.ByteBuffer probe = java.nio.ByteBuffer.allocate(4096);
            for (int w = 1; w < chunks; w++) {
                long at = size / chunks * w - 1, found = size;
                outer:
                while (at < size) {
                    probe.clear();
                    int got = ch.read(probe, at);
                    if (got <= 0) break;
                    for (int k = 0; k < got; k++) {
                        if (probe.get(k) == '\n') { found = at + k + 1; break outer; }
                    }
                    at += got;
                }
                bounds[w] = Math.max(found, bounds[w - 1]);
            }
            bounds[chunks] = size;

            Part[] parts = new Part[chunks];
            List<Thread> threads = new ArrayList<>();
            java.util.concurrent.atomic.AtomicInteger next = new java.util.concurrent.atomic.AtomicInteger();
            for (int t = 0; t < Math.min(workers, chunks); t++) {
                Thread th = new Thread(() -> {
                    int c;
                    while ((c = next.getAndIncrement()) < parts.length) {
                        Part p = new Part();
                        try { work(ch, bounds[c], bounds[c + 1], p); } catch (IOException e) { throw new RuntimeException(e); }
                        parts[c] = p;
                    }
                });
                th.start();
                threads.add(th);
            }
            for (Thread th : threads) th.join();

            Part total = parts[0];
            for (int c = 1; c < parts.length; c++) {
                Part p = parts[c];
                total.rows += p.rows;
                for (int k = 0; k < total.regions.length; k++) total.regions[k] += p.regions[k];
                for (int k = 0; k < p.users.keys.length; k++) if (p.users.keys[k] != 0) total.users.add(p.users.keys[k] - 1, p.users.vals[k]);
                for (int k = 0; k < p.skus.a.length; k++) if (p.skus.lens[k] != 0) total.skus.add(p.skus.a[k], p.skus.b[k], p.skus.lens[k], p.skus.vals[k]);
                parts[c] = null;
            }

            long[] topRev = new long[100], topUser = new long[100];
            int nu = 0;
            LongMap u = total.users;
            for (int k = 0; k < u.keys.length; k++) {
                if (u.keys[k] == 0) continue;
                long rev = u.vals[k], user = u.keys[k] - 1;
                if (nu == 100 && !(rev > topRev[99] || (rev == topRev[99] && user < topUser[99]))) continue;
                int at = nu < 100 ? nu++ : 99;
                while (at > 0 && (rev > topRev[at - 1] || (rev == topRev[at - 1] && user < topUser[at - 1]))) {
                    topRev[at] = topRev[at - 1];
                    topUser[at] = topUser[at - 1];
                    at--;
                }
                topRev[at] = rev;
                topUser[at] = user;
            }
            long[] sRev = new long[10];
            String[] sName = new String[10];
            int ns = 0;
            SkuMap s = total.skus;
            for (int k = 0; k < s.a.length; k++) {
                if (s.lens[k] == 0) continue;
                long rev = s.vals[k];
                if (ns == 10 && rev < sRev[9]) continue;
                String name = sku(s.a[k], s.b[k], s.lens[k]);
                if (ns == 10 && !(rev > sRev[9] || name.compareTo(sName[9]) < 0)) continue;
                int at = ns < 10 ? ns++ : 9;
                while (at > 0 && (rev > sRev[at - 1] || (rev == sRev[at - 1] && name.compareTo(sName[at - 1]) < 0))) {
                    sRev[at] = sRev[at - 1];
                    sName[at] = sName[at - 1];
                    at--;
                }
                sRev[at] = rev;
                sName[at] = name;
            }

            PrintStream out = new PrintStream(new BufferedOutputStream(System.out, 1 << 16), false);
            out.print("rows=" + total.rows + "\n");
            for (int c = 0; c < 676; c++) {
                if (total.regions[c * 3] == 0) continue;
                out.print("region=" + (char) ('A' + c / 26) + (char) ('A' + c % 26) + " count=" + total.regions[c * 3]
                        + " qty=" + total.regions[c * 3 + 1] + " revenue=" + total.regions[c * 3 + 2] + "\n");
            }
            for (int i = 0; i < nu; i++) out.print("top_user rank=" + (i + 1) + " user_id=" + topUser[i] + " revenue=" + topRev[i] + "\n");
            for (int i = 0; i < ns; i++) out.print("top_sku rank=" + (i + 1) + " sku=" + sName[i] + " revenue=" + sRev[i] + "\n");
            out.flush();
        }
    }
}
