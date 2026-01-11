import "package:flutter/material.dart";

void main() {
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: Text("My App"),
          backgroundColor: Colors.brown,
          centerTitle: true,
        ),
        body: Text("Body"),
      ),
    ),
  );
}
