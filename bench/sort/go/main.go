// The Go counterpart of ../main.sl: byte-identical inputs (same lcf,
// same seed 12345, same per-scene state chain), same 5-round
// copy-and-time loop with verification off the clock, same
// scene,NAME,n,MEDIAN_MS lines. Uses the standard sort package:
// sort.Ints, sort.Float64s, sort.Strings, sort.Slice with key-field
// comparators, and sort.SliceStable.
package main

import (
	"fmt"
	"sort"
	"time"
)

const rounds = 5

// two-step Lehmer walk, bounded multiplier: never overflows int64
func lcf(x int64) int64 {
	q := (x * 48271) % 2147483647
	return (q * 48271) % 2147483647
}

// the square-and-mod step that keeps small moduli honest; see the
// header note in ../main.sl for why a pure chain mod a prime
// degenerates (short periods mod 4 and mod 6)
func mix(x int64) int64 {
	t := lcf(x)
	return (t * t) % 2147483647
}

type Row struct {
	id  int
	tag string
	oi  int
}

func genInts(n int) []int {
	out := make([]int, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, int(mix(12345+3*int64(i)))%1000003-500000)
	}
	return out
}

func genIntsEq4(n int) []int {
	out := make([]int, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, int(mix(12345+3*int64(i)))%4)
	}
	return out
}

func genFloats(n int) []float64 {
	out := make([]float64, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, float64(int(mix(12345+3*int64(i)))%1000003-500000)/1000.0)
	}
	return out
}

func genStrAt(i int) string {
	ln := int(mix(12345+3*int64(i)))%6 + 4
	bs := make([]byte, ln)
	for k := 0; k < ln; k++ {
		bs[k] = byte(int(mix(12345+3*int64(i)+1+int64(k)))%26 + 97)
	}
	return string(bs)
}

func report(name string, n int, ms float64) {
	fmt.Printf("scene,%s,%d,%.3f\n", name, n, ms)
}

func medianOf(ts []float64) float64 {
	sort.Float64s(ts)
	return ts[len(ts)/2]
}

func msInts(name string, src []int) {
	n := len(src)
	ts := make([]float64, 0, rounds)
	for r := 0; r < rounds; r++ {
		work := make([]int, n)
		copy(work, src)
		t0 := time.Now()
		sort.Ints(work)
		ms := float64(time.Since(t0).Nanoseconds()) / 1e6
		ts = append(ts, ms)
		for c := 1; c < n; c++ {
			if work[c-1] > work[c] {
				panic(name + " not sorted")
			}
		}
	}
	report(name, n, medianOf(ts))
}

func msFloats(name string, src []float64) {
	n := len(src)
	ts := make([]float64, 0, rounds)
	for r := 0; r < rounds; r++ {
		work := make([]float64, n)
		copy(work, src)
		t0 := time.Now()
		sort.Float64s(work)
		ms := float64(time.Since(t0).Nanoseconds()) / 1e6
		ts = append(ts, ms)
		for c := 1; c < n; c++ {
			if work[c] < work[c-1] {
				panic(name + " not sorted")
			}
		}
	}
	report(name, n, medianOf(ts))
}

func msStrs(name string, src []string) {
	n := len(src)
	ts := make([]float64, 0, rounds)
	for r := 0; r < rounds; r++ {
		work := make([]string, n)
		copy(work, src)
		t0 := time.Now()
		sort.Strings(work)
		ms := float64(time.Since(t0).Nanoseconds()) / 1e6
		ts = append(ts, ms)
		for c := 1; c < n; c++ {
			if work[c-1] > work[c] {
				panic(name + " not sorted")
			}
		}
	}
	report(name, n, medianOf(ts))
}

func msByInt(name string, src []Row) {
	n := len(src)
	ts := make([]float64, 0, rounds)
	for r := 0; r < rounds; r++ {
		work := make([]Row, n)
		copy(work, src)
		t0 := time.Now()
		sort.Slice(work, func(i, j int) bool { return work[i].id < work[j].id })
		ms := float64(time.Since(t0).Nanoseconds()) / 1e6
		ts = append(ts, ms)
		for c := 1; c < n; c++ {
			if work[c].id < work[c-1].id {
				panic(name + " not sorted")
			}
		}
	}
	report(name, n, medianOf(ts))
}

func msByStr(name string, src []Row) {
	n := len(src)
	ts := make([]float64, 0, rounds)
	for r := 0; r < rounds; r++ {
		work := make([]Row, n)
		copy(work, src)
		t0 := time.Now()
		sort.Slice(work, func(i, j int) bool { return work[i].tag < work[j].tag })
		ms := float64(time.Since(t0).Nanoseconds()) / 1e6
		ts = append(ts, ms)
		for c := 1; c < n; c++ {
			if work[c].tag < work[c-1].tag {
				panic(name + " not sorted")
			}
		}
	}
	report(name, n, medianOf(ts))
}

func msByStable(name string, src []Row) {
	n := len(src)
	ts := make([]float64, 0, rounds)
	for r := 0; r < rounds; r++ {
		work := make([]Row, n)
		copy(work, src)
		t0 := time.Now()
		sort.SliceStable(work, func(i, j int) bool { return work[i].tag < work[j].tag })
		ms := float64(time.Since(t0).Nanoseconds()) / 1e6
		ts = append(ts, ms)
		for c := 1; c < n; c++ {
			if work[c].tag < work[c-1].tag {
				panic(name + " not sorted")
			}
			if work[c].tag == work[c-1].tag && work[c].oi < work[c-1].oi {
				panic(name + " not stable")
			}
		}
	}
	report(name, n, medianOf(ts))
}

func main() {
	msInts("ints_random_1k", genInts(1000))
	msInts("ints_random_100k", genInts(100000))
	msInts("ints_random_1m", genInts(1000000))

	asc := make([]int, 0, 1000000)
	for i := 0; i < 1000000; i++ {
		asc = append(asc, i*11-5000)
	}
	msInts("ints_sorted_1m", asc)

	de := make([]int, 0, 1000000)
	for i := 0; i < 1000000; i++ {
		de = append(de, 499999-i)
	}
	msInts("ints_desc_1m", de)

	msInts("ints_equal_1m", genIntsEq4(1000000))

	msFloats("floats_random_1m", genFloats(1000000))

	strs := make([]string, 0, 100000)
	for i := 0; i < 100000; i++ {
		strs = append(strs, genStrAt(i))
	}
	msStrs("strings_random_100k", strs)

	r1 := make([]Row, 0, 250000)
	for i := 0; i < 250000; i++ {
		r1 = append(r1, Row{id: (int(mix(12345+3*int64(i)))%1000003 - 500000) * 1000, oi: i})
	}
	msByInt("by_int_250k", r1)

	r2 := make([]Row, 0, 250000)
	for i := 0; i < 250000; i++ {
		r2 = append(r2, Row{id: i * 11, oi: i})
	}
	msByInt("by_int_sorted_250k", r2)

	r3 := make([]Row, 0, 100000)
	for i := 0; i < 100000; i++ {
		tag := fmt.Sprintf("g%d", int(mix(12345+3*int64(i)+1))%6)
		r3 = append(r3, Row{tag: tag, oi: i})
	}
	msByStr("by_str_100k", r3)
	msByStable("by_stable_100k", r3)
}
