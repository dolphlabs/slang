// lifetime parameters on a generic struct are not part of this step.
struct View[T]<'a> { v: &'a T }
