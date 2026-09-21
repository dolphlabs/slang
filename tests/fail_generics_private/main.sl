// a generic struct not marked pub cannot be instantiated from another package.
import "stash";

fn f(h: stash.Hidden[int]) {}
