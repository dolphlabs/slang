// heavy/batch in C#: MemoryMappedFile, a thread per core over newline-
// aligned ranges, Dictionary per thread updated in place through
// CollectionsMarshal, merged at the end. See bench/SPEC.md.
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Text;

unsafe
{
    string path = args[0];
    long size = new FileInfo(path).Length;
    int workers = int.TryParse(Environment.GetEnvironmentVariable("WORKERS"), out var w) && w > 0 ? w : Environment.ProcessorCount;
    workers = (int)Math.Min(workers, size / 65536 + 1);

    using var mmf = MemoryMappedFile.CreateFromFile(path, FileMode.Open, null, 0, MemoryMappedFileAccess.Read);
    using var view = mmf.CreateViewAccessor(0, size, MemoryMappedFileAccess.Read);
    byte* data = null;
    view.SafeMemoryMappedViewHandle.AcquirePointer(ref data);
    data += view.PointerOffset;

    long[] bounds = new long[workers + 1];
    for (int i = 1; i < workers; i++) {
        long at = size / workers * i;
        while (at < size && data[at - 1] != '\n') at++;
        bounds[i] = Math.Max(at, bounds[i - 1]);
    }
    bounds[workers] = size;

    var parts = new Part[workers];
    var threads = new Thread[workers];
    for (int i = 0; i < workers; i++) {
        int idx = i;
        byte* d = data;
        threads[i] = new Thread(() => parts[idx] = Part.Run(d, bounds[idx], bounds[idx + 1]));
        threads[i].Start();
    }
    foreach (var t in threads) t.Join();

    var total = parts[0];
    for (int i = 1; i < workers; i++) {
        var p = parts[i];
        total.Rows += p.Rows;
        for (int k = 0; k < total.Regions.Length; k++) total.Regions[k] += p.Regions[k];
        foreach (var (u, v) in p.Users) CollectionsMarshal.GetValueRefOrAddDefault(total.Users, u, out _) += v;
        foreach (var (s, v) in p.Skus) CollectionsMarshal.GetValueRefOrAddDefault(total.Skus, s, out _) += v;
        parts[i] = null!;
    }

    var topRev = new long[100];
    var topUser = new long[100];
    int nu = 0;
    foreach (var (u, rev) in total.Users) {
        if (nu == 100 && !(rev > topRev[99] || (rev == topRev[99] && u < topUser[99]))) continue;
        int at = nu < 100 ? nu++ : 99;
        while (at > 0 && (rev > topRev[at - 1] || (rev == topRev[at - 1] && u < topUser[at - 1]))) {
            topRev[at] = topRev[at - 1];
            topUser[at] = topUser[at - 1];
            at--;
        }
        topRev[at] = rev;
        topUser[at] = u;
    }
    var skus = total.Skus.ToList();
    skus.Sort((a, b) => a.Value != b.Value ? b.Value.CompareTo(a.Value) : string.CompareOrdinal(a.Key, b.Key));

    var sb = new StringBuilder(16 * 1024);
    sb.Append("rows=").Append(total.Rows).Append('\n');
    for (int c = 0; c < 676; c++) {
        if (total.Regions[c * 3] == 0) continue;
        sb.Append("region=").Append((char)('A' + c / 26)).Append((char)('A' + c % 26))
          .Append(" count=").Append(total.Regions[c * 3]).Append(" qty=").Append(total.Regions[c * 3 + 1])
          .Append(" revenue=").Append(total.Regions[c * 3 + 2]).Append('\n');
    }
    for (int i = 0; i < nu; i++)
        sb.Append("top_user rank=").Append(i + 1).Append(" user_id=").Append(topUser[i]).Append(" revenue=").Append(topRev[i]).Append('\n');
    for (int i = 0; i < Math.Min(10, skus.Count); i++)
        sb.Append("top_sku rank=").Append(i + 1).Append(" sku=").Append(skus[i].Key).Append(" revenue=").Append(skus[i].Value).Append('\n');
    using var stdout = Console.OpenStandardOutput();
    stdout.Write(Encoding.ASCII.GetBytes(sb.ToString()));
    view.SafeMemoryMappedViewHandle.ReleasePointer();
}

sealed class Part {
    public long Rows;
    public readonly long[] Regions = new long[676 * 3];
    public readonly Dictionary<long, long> Users = new(1 << 20);
    public readonly Dictionary<string, long> Skus = new(1 << 17);

    public static unsafe Part Run(byte* data, long start, long end) {
        var p = new Part();
        // one string per distinct sku: look the bytes up before allocating
        var skuLookup = p.Skus.GetAlternateLookup<ReadOnlySpan<char>>();
        Span<char> skuChars = stackalloc char[32];
        long i = start;
        while (i < end) {
            while (data[i] != ',') i++;
            i++;
            long user = 0;
            while (data[i] != ',') user = user * 10 + (data[i++] - '0');
            i++;
            int n = 0;
            while (data[i] != ',') {
                if (n < skuChars.Length) skuChars[n++] = (char)data[i];
                i++;
            }
            i++;
            long qty = 0;
            while (data[i] != ',') qty = qty * 10 + (data[i++] - '0');
            i++;
            long price = 0;
            while (data[i] != ',') price = price * 10 + (data[i++] - '0');
            i++;
            int r = ((data[i] - 'A') * 26 + (data[i + 1] - 'A')) * 3;
            i += 3;
            long rev = qty * price;
            p.Regions[r]++;
            p.Regions[r + 1] += qty;
            p.Regions[r + 2] += rev;
            p.Rows++;
            CollectionsMarshal.GetValueRefOrAddDefault(p.Users, user, out _) += rev;
            var key = skuChars[..n];
            if (skuLookup.TryGetValue(key, out long cur)) skuLookup[key] = cur + rev;
            else p.Skus[new string(key)] = rev;
        }
        return p;
    }
}
