void main() {
  // classicFunction();
  // playGroundFunction();
  printName("Birungi Samantha", 6);
}

// classicFunction() {
//   print("This is a classic function");
// }

// playGroundFunction() {
//   print("object");
// }

void printName(String name, int age) {
  print("My name is $name and I am $age ${age == 1 ? "year" : "years"} old.");

  unnamed();

  duplicate("Mikey", times: 4);
}

void unnamed({String? name, int? age}) {
  final actualName = name ?? "Unkown";
  final actualAge = age ?? 0;

  if (actualName == "Unknown" && actualAge == 0) {
    print("Name and age are required.");
  } else {
    print("Name: $actualName, Age: $actualAge");
  }
}

duplicate(String name, {int times = 0}) {
  for (var i = 0; i < times; i++) {
    print(name);
  }
}
