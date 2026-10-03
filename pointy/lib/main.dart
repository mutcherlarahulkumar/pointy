import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Pointy')),
        body: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Trip Wallet'),
            Text('\$12,500',style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
            Text('4 Members')
          ],
        ),
        ),
      ),
    );
  }
}