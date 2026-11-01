import Foundation
@main struct Runner {
 static func main() {
  do {let book=try BookImporter.convert(URL(fileURLWithPath:CommandLine.arguments[1]));try book.package.write(to:URL(fileURLWithPath:CommandLine.arguments[2]));print(book.id)}catch{fputs(error.localizedDescription+"\n",stderr);exit(1)}
 }
}
