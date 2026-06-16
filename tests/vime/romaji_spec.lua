local romaji = require("vime.romaji")

describe("vime.romaji.to_kana", function()
  local function check(cases)
    for _, c in ipairs(cases) do
      assert.are.equal(c[2], romaji.to_kana(c[1]), "input: " .. c[1])
    end
  end

  it("converts basic gojuon / dakuon / handakuon", function()
    check({
      { "aiueo", "あいうえお" },
      { "ka", "か" }, { "ki", "き" }, { "ku", "く" }, { "ke", "け" }, { "ko", "こ" },
      { "ga", "が" }, { "pa", "ぱ" }, { "za", "ざ" }, { "da", "だ" },
      { "watashi", "わたし" }, { "wo", "を" },
    })
  end)

  it("converts youon (contracted) and foreign sounds", function()
    check({
      { "kyou", "きょう" },
      { "sha", "しゃ" }, { "sya", "しゃ" },
      { "cha", "ちゃ" }, { "tya", "ちゃ" },
      { "ja", "じゃ" }, { "jya", "じゃ" },
      { "fa", "ふぁ" }, { "che", "ちぇ" }, { "fe", "ふぇ" },
      { "jugyou", "じゅぎょう" },
    })
  end)

  it("converts sokuon (geminate)", function()
    check({
      { "tte", "って" },
      { "kekka", "けっか" },
      { "matcha", "まっちゃ" },
      { "kippu", "きっぷ" },
      { "issho", "いっしょ" },
      { "tukatte", "つかって" },
    })
  end)

  it("converts hatsuon (n) with correct look-ahead", function()
    check({
      { "kanji", "かんじ" },
      { "konnichiha", "こんにちは" },
      { "onna", "おんな" },
      { "annai", "あんない" },
      { "tennki", "てんき" },
      { "iitenki", "いいてんき" },
      { "iitennki", "いいてんき" },
      { "nn", "ん" },
      { "n", "ん" },
      { "honya", "ほにゃ" },
      { "hon'ya", "ほんや" },
      { "shinbun", "しんぶん" },
    })
  end)

  it("lowercases uppercase input", function()
    check({
      { "Kyou", "きょう" },
      { "KANJI", "かんじ" },
    })
  end)

  it("passes through undefined characters", function()
    check({
      { "3ji", "3じ" },
    })
  end)

  it("converts the long-vowel mark and passes through other symbols", function()
    check({
      { "-", "ー" },
      { "su-pa-", "すーぱー" },
      { "a!b", "あ!b" },
    })
  end)

  it("converts Japanese punctuation and brackets", function()
    check({
      { ",", "、" },
      { ".", "。" },
      { "/", "・" },
      { "[", "「" },
      { "]", "」" },
      { "a,i.", "あ、い。" },
    })
  end)

  it("converts hiragana to katakana (others unchanged)", function()
    assert.are.equal("キョウ", romaji.to_katakana("きょう"))
    assert.are.equal("ファイル", romaji.to_katakana("ふぁいる"))
    assert.are.equal("ヴ", romaji.to_katakana("ゔ"))
    assert.are.equal("カー、A", romaji.to_katakana("かー、A")) -- ー/、/英字 はそのまま
  end)

  it("converts the full target sentence", function()
    assert.are.equal("きょうはいいてんきだね", romaji.to_kana("kyouhaiitenkidane"))
  end)
end)
