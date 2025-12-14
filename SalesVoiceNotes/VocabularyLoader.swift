import Foundation

/// 音声認識用のカスタム語彙をJSONファイルから読み込むローダー
enum VocabularyLoader {
    
    /// JSONファイルの構造
    private struct VocabularyFile: Codable {
        let description: String?
        let usage: String?
        let categories: [String: Category]
        
        struct Category: Codable {
            let description: String?
            let words: [String]
        }
    }
    
    /// 全てのカスタム語彙を読み込む
    /// - Returns: カスタム語彙の配列
    static func loadAll() -> [String] {
        guard let url = Bundle.main.url(forResource: "vocabulary", withExtension: "json") else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(VocabularyFile.self, from: data)
            
            // 全カテゴリの単語を結合
            var allWords: [String] = []
            for (_, category) in file.categories {
                allWords.append(contentsOf: category.words)
            }
            
            return allWords
            
        } catch {
            return []
        }
    }
    
    /// 特定のカテゴリの語彙のみを読み込む
    /// - Parameter categoryName: カテゴリ名（例: "sales", "technology"）
    /// - Returns: カテゴリ内の語彙の配列
    static func load(category categoryName: String) -> [String] {
        guard let url = Bundle.main.url(forResource: "vocabulary", withExtension: "json") else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(VocabularyFile.self, from: data)
            
            guard let category = file.categories[categoryName] else {
                return []
            }
            
            return category.words
            
        } catch {
            return []
        }
    }
}
