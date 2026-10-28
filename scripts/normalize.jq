.rules |= map(with_entries(.value |= if type == "array" then sort | unique else . end))
