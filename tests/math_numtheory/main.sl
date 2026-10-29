// math/numtheory on cases Python confirms: modular powers and inverses,
// Miller-Rabin on the largest int prime and on a strong pseudoprime to
// bases 2, 3, 5 and 7, factorization by Pollard's rho of a product of two
// 10-digit primes and of min_int, the CRT with contradicting moduli.
import "math";
import "math/numtheory";
println(numtheory.mod_pow(2, 100, 1000000007));
println(numtheory.mod_pow(-3, 3, 7));
println(numtheory.mod_inv(3, 7) ?? -1);
println(numtheory.mod_inv(4, 8) ?? -1);
println(inspect(numtheory.ext_gcd(240, 46)));
println(numtheory.is_prime(1000000007));
println(numtheory.is_prime(9223372036854775783));
println(numtheory.is_prime(3215031751));
println(numtheory.is_prime(1));
println(numtheory.next_prime(1000000000) ?? -1);
println(numtheory.prev_prime(100) ?? -1);
println(inspect(numtheory.primes_below(30)));
println(len(numtheory.primes_below(1000000)));
println(inspect(numtheory.factorize(360)));
println(inspect(numtheory.factorize(math.min_int)));
println(inspect(numtheory.factorize(600851475143)));
println(inspect(numtheory.factorize(9223372036854775783)));
println(inspect(numtheory.factorize(1000000016000000063)));
println(inspect(numtheory.divisors(36)));
println(numtheory.totient(36));
println(numtheory.crt([2, 3, 2], [3, 5, 7]) ?? -1);
println(numtheory.crt([1, 2], [4, 6]) ?? -1);
println(numtheory.crt([3, 5], [4, 6]) ?? -1);
println(numtheory.binomial_mod(1000000, 500000, 1000003));
println(numtheory.fibonacci(92) ?? -1);
println(numtheory.fibonacci(10) ?? -1);
println(numtheory.fibonacci(93) ?? -1);
