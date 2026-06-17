local skk = require("vime.skk")

describe("vime.skk.clean_candidate", function()
  it("strips the annotation after a semicolon", function()
    assert.are.equal("愛知大学", skk.clean_candidate("愛知大学;※abbrev"))
  end)

  it("keeps a candidate that has no annotation", function()
    assert.are.equal("渡", skk.clean_candidate("渡"))
  end)

  it("keeps parentheses that are part of the word", function()
    assert.are.equal("(株)百五銀行", skk.clean_candidate("(株)百五銀行"))
  end)

  it("rejects a numeric template candidate", function()
    assert.is_nil(skk.clean_candidate("安政#2年"))
  end)

  it("rejects a concat lisp candidate", function()
    assert.is_nil(skk.clean_candidate('(concat "1\\057")'))
  end)

  it("rejects an empty candidate", function()
    assert.is_nil(skk.clean_candidate(""))
  end)

  it("rejects a candidate that is only an annotation", function()
    assert.is_nil(skk.clean_candidate(";only-annotation"))
  end)
end)

describe("vime.skk.entries", function()
  it("expands each candidate of a reading into its own entry", function()
    local entries = skk.entries({ okuri_ari = {}, okuri_nasi = { ["かつえ"] = { "餓え", "飢え" } } })
    assert.are.same({ { yomi = "かつえ", word = "餓え" }, { yomi = "かつえ", word = "飢え" } }, entries)
  end)

  it("strips annotations from candidates", function()
    local entries = skk.entries({ okuri_ari = {}, okuri_nasi = { ["あい"] = { "愛;love" } } })
    assert.are.same({ { yomi = "あい", word = "愛" } }, entries)
  end)

  it("ignores okuri_ari entries", function()
    local entries = skk.entries({ okuri_ari = { ["わたr"] = { "渡" } }, okuri_nasi = {} })
    assert.are.same({}, entries)
  end)

  it("skips readings that contain a numeric template marker", function()
    local entries = skk.entries({ okuri_ari = {}, okuri_nasi = { ["あんせい#ねん"] = { "安政#2年" } } })
    assert.are.same({}, entries)
  end)

  it("reports counts of imported and skipped candidates", function()
    local entries, stats = skk.entries({ okuri_ari = {}, okuri_nasi = { ["あい"] = { "愛", '(concat "x")' } } })
    assert.are.same({ { yomi = "あい", word = "愛" } }, entries)
    assert.are.same({ entries = 1, skipped = 1 }, stats)
  end)
end)

describe("vime.skk.decode", function()
  it("decodes a valid JISYO JSON string into a table", function()
    local decoded = skk.decode('{"okuri_ari":{},"okuri_nasi":{"あい":["愛"]}}')
    assert.are.same({ "愛" }, decoded.okuri_nasi["あい"])
  end)

  it("returns nil for invalid JSON without raising", function()
    assert.is_nil(skk.decode("{not valid json"))
  end)
end)

describe("vime.skk.to_lines", function()
  it("formats entries as 読み #T35*1 単語 lines", function()
    local lines = skk.to_lines({ { yomi = "あい", word = "愛" }, { yomi = "ぶいめ", word = "vime" } })
    assert.are.same({ "あい #T35*1 愛", "ぶいめ #T35*1 vime" }, lines)
  end)

  it("skips entries whose yomi or word contains whitespace", function()
    local lines, skipped = skk.to_lines({ { yomi = "あ い", word = "愛" }, { yomi = "ねこ", word = "猫 又" } })
    assert.are.same({}, lines)
    assert.are.equal(2, skipped)
  end)
end)

describe("vime.skk.sort_unique", function()
  it("removes duplicates and sorts lines in byte order", function()
    local out = skk.sort_unique({
      "さ #T35*1000 X",
      "あ #T35*1000 Y",
      "あ #T35*1000 Y",
      "か #T35*1000 Z",
    })
    assert.are.same({ "あ #T35*1000 Y", "か #T35*1000 Z", "さ #T35*1000 X" }, out)
  end)
end)

describe("vime.skk.load", function()
  local function write_json(tbl)
    local path = vim.fn.tempname()
    vim.fn.writefile({ vim.json.encode(tbl) }, path)
    return path
  end

  it("registers every cleaned okuri_nasi entry from a JISYO json file", function()
    local path = write_json({
      copyright = "c",
      license = "l",
      okuri_ari = {},
      okuri_nasi = { ["あい"] = { "愛;love", '(concat "x")' }, ["ぶいめ"] = { "vime" } },
    })
    local calls = {}
    local stats = skk.load(path, function(yomi, word)
      calls[#calls + 1] = { yomi = yomi, word = word }
    end)
    assert.are.same({ entries = 2, skipped = 1 }, stats)
    table.sort(calls, function(a, b)
      return a.yomi < b.yomi
    end)
    assert.are.same({ { yomi = "あい", word = "愛" }, { yomi = "ぶいめ", word = "vime" } }, calls)
    vim.fn.delete(path)
  end)

  it("returns nil and does not register when the file is missing", function()
    local calls = 0
    local stats = skk.load("/no/such/vime-dict.json", function()
      calls = calls + 1
    end)
    assert.is_nil(stats)
    assert.are.equal(0, calls)
  end)

  it("returns nil for invalid JSON content", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "{ not valid json" }, path)
    local calls = 0
    local stats = skk.load(path, function()
      calls = calls + 1
    end)
    assert.is_nil(stats)
    assert.are.equal(0, calls)
    vim.fn.delete(path)
  end)
end)
