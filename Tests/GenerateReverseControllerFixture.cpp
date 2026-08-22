#include "Support/SyntheticMDictFixture.h"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>

int main(int argc, char **argv) {
  if (argc < 2 || argc > 3) {
    std::cerr << "usage: GenerateReverseControllerFixture OUTPUT.mdx "
                 "[default|late-chinese|english-only]\n";
    return 2;
  }
  try {
    const std::filesystem::path output(argv[1]);
    std::filesystem::create_directories(output.parent_path());
    const auto record = [](const std::string &headword,
                           const std::string &chinese) {
      return "<div><ul><li class=\"wordgroup\"><span class=\"pos\">noun</span>"
             "<span class=\"def\">" + chinese +
             "</span></li></ul><div class=\"p-g\"><div class=\"n-g\">"
             "<div class=\"def-g\">definition <span class=\"oalecd8e_chn\">" +
             chinese + "</span></div></div></div><font color=\"darkcyan\">" + headword +
             "</font><font color=\"navy\">" + chinese +
             "</font><div class=\"javascript_tittle_box\">释义</div>"
             "<div class=\"dict_content_display\">" + chinese + "</div></div>";
    };
    const std::string mode = argc == 3 ? argv[2] : "default";
    std::vector<std::pair<std::string, std::string>> entries;
    if (mode == "default") {
      entries = {
          {"apple", record("apple", "苹果；蘋果；苹果树的果实")},
          {"download", record("download", "下载；把数据传到本地")},
          {"kidney", record("kidney", "肾脏；腎臟")},
          {"liver", record("liver", "肝脏；肝臟")},
          {"validation", record("validation", "验证；驗證；确认有效性")},
      };
    } else if (mode == "late-chinese" || mode == "english-only") {
      // The automatic production probe reads at most 512 entries. Keep the first
      // reliable Chinese gloss at entry 513 so this fixture proves that a full
      // user-requested scan does not repeat the same bounded sample forever.
      for (int index = 1; index <= 513; ++index) {
        char headword[32];
        std::snprintf(headword, sizeof(headword), "entry-%04d", index);
        std::string definition =
            "<div><span class=\"pos\">noun</span><span class=\"def\">"
            "English definition number " + std::to_string(index) +
            "</span></div>";
        if (mode == "late-chinese" && index == 513) {
          definition = record(headword, "苹果；可用中文释义");
        }
        entries.emplace_back(headword, std::move(definition));
      }
    } else {
      throw std::runtime_error("unknown fixture mode: " + mode);
    }
    const auto bytes =
        localdict::testsupport::BuildSyntheticMDXWithEntries(entries);
    std::ofstream stream(output, std::ios::binary | std::ios::trunc);
    stream.write(reinterpret_cast<const char *>(bytes.data()),
                 static_cast<std::streamsize>(bytes.size()));
    if (!stream) throw std::runtime_error("cannot write fixture");
    std::cout << output << " bytes=" << bytes.size() << "\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << "\n";
    return 1;
  }
}
