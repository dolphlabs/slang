pub struct Item {
    id: int,
    label: str,
}

pub fn make(
    id: int,
    label: str,
) -> Item {
    return Item {
        id: id,
        label: label,
    };
}
