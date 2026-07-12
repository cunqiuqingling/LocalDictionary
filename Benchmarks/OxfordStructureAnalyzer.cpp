#include <libxml/HTMLparser.h>
#include <libxml/tree.h>

#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>

namespace {
const std::set<std::string> semanticClasses = {
    "entry", "h-g", "top-g", "h", "ei-g", "phon-gb", "phon-us",
    "phon-usgb", "infl", "inflection", "block-g", "pos-g", "pos",
    "sense-g", "n-g", "z_n", "def-g", "d", "oalecd8e_chn", "x-g",
    "x", "xr-g", "symbols-synsym", "symbols-oppsym", "xr", "xh",
    "derived", "dr-g", "dr", "id-g", "id", "pv-g", "pv", "table",
    "title", "subhead", "collsubhead", "langbanksubhead", "para"};

std::string property(xmlNodePtr node, const char *name) {
  xmlChar *value = xmlGetProp(node, BAD_CAST name);
  if (!value) return {};
  std::string result(reinterpret_cast<const char *>(value));
  xmlFree(value);
  return result;
}

std::set<std::string> classes(xmlNodePtr node) {
  std::set<std::string> result;
  std::istringstream input(property(node, "class"));
  for (std::string value; input >> value;) result.insert(value);
  return result;
}

size_t textCharacters(xmlNodePtr node) {
  xmlChar *content = xmlNodeGetContent(node);
  if (!content) return 0;
  const size_t count = xmlUTF8Strlen(content);
  xmlFree(content);
  return count;
}

bool semantic(xmlNodePtr node) {
  const auto values = classes(node);
  return std::any_of(values.begin(), values.end(), [](const auto &value) {
    return semanticClasses.contains(value);
  });
}

void collect(xmlNodePtr node, std::map<std::string, size_t> &tags,
             std::map<std::string, size_t> &classCounts) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE) continue;
    ++tags[reinterpret_cast<const char *>(current->name)];
    for (const auto &value : classes(current)) ++classCounts[value];
    collect(current->children, tags, classCounts);
  }
}

void printSemanticTree(xmlNodePtr node, int semanticDepth = 0) {
  for (xmlNodePtr current = node; current; current = current->next) {
    if (current->type != XML_ELEMENT_NODE) continue;
    const bool include = semantic(current);
    if (include) {
      std::cout << std::string(semanticDepth * 2, ' ')
                << reinterpret_cast<const char *>(current->name);
      const std::string className = property(current, "class");
      if (!className.empty()) std::cout << "." << className;
      std::cout << " chars=" << textCharacters(current) << "\n";
    }
    printSemanticTree(current->children, semanticDepth + (include ? 1 : 0));
  }
}
}  // namespace

int main(int argc, char **argv) {
  if (argc < 2) return 64;
  for (int index = 1; index < argc; ++index) {
    std::ifstream stream(argv[index], std::ios::binary);
    std::ostringstream buffer;
    buffer << stream.rdbuf();
    const std::string html = buffer.str();
    htmlDocPtr document = htmlReadMemory(
        html.data(), static_cast<int>(html.size()), nullptr, "UTF-8",
        HTML_PARSE_RECOVER | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING |
            HTML_PARSE_NONET | HTML_PARSE_COMPACT);
    if (!document) return 1;

    std::map<std::string, size_t> tags;
    std::map<std::string, size_t> classCounts;
    collect(xmlDocGetRootElement(document), tags, classCounts);
    std::cout << "FILE " << argv[index] << " bytes=" << html.size() << "\nTAGS";
    for (const auto &[name, count] : tags) std::cout << " " << name << "=" << count;
    std::cout << "\nCLASSES";
    for (const auto &[name, count] : classCounts) std::cout << " " << name << "=" << count;
    std::cout << "\nHIERARCHY\n";
    printSemanticTree(xmlDocGetRootElement(document));
    xmlFreeDoc(document);
  }
  xmlCleanupParser();
  return 0;
}
