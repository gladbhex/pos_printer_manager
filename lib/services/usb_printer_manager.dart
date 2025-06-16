import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter_usb_printer/flutter_usb_printer.dart';
import 'package:win32/win32.dart';
import 'package:pos_printer_manager/models/pos_printer.dart';
import 'package:pos_printer_manager/pos_printer_manager.dart';
import 'package:pos_printer_manager/services/printer_manager.dart';
import 'extension.dart';
import 'usb_service.dart';

/// USB Printer
class USBPrinterManager extends PrinterManager {
  Generator? generator;

  /// usb_serial
  var usbPrinter = FlutterUsbPrinter();

  /// [win32]
  Pointer<IntPtr>? phPrinter = calloc<HANDLE>();
  Pointer<Utf16> pDocName = 'My Document'.toNativeUtf16();
  Pointer<Utf16> pDataType = 'RAW'.toNativeUtf16();
  Pointer<Uint32>? dwBytesWritten = calloc<DWORD>();
  Pointer<DOC_INFO_1>? docInfo;
  late Pointer<Utf16> szPrinterName;
  late int hPrinter;
  int? dwCount;

  USBPrinterManager(
    POSPrinter printer,
    PaperSize paperSize,
    CapabilityProfile profile, {
    int spaceBetweenRows = 5,
    int port = 9100,
  }) {
    super.printer = printer;
    super.address = printer.address;
    super.productId = printer.productId;
    super.deviceId = printer.deviceId;
    super.vendorId = printer.vendorId;
    super.paperSize = paperSize;
    super.profile = profile;
    super.spaceBetweenRows = spaceBetweenRows;
    super.port = port;
    generator =
        Generator(paperSize, profile, spaceBetweenRows: spaceBetweenRows);
  }

  @override
  Future<ConnectionResponse> connect(
      {Duration? timeout = const Duration(seconds: 5)}) async {
    if (Platform.isWindows) {
    try {
      final pDocName = 'My Document'.toNativeUtf16();
      final pDataType = 'RAW'.toNativeUtf16();
      final printerNamePtr = printer.name!.toNativeUtf16();
      final printerHandlePtr = calloc<HANDLE>();
      final docInfo = calloc<DOC_INFO_1>();

      docInfo.ref
        ..pDocName = pDocName
        ..pOutputFile = nullptr
        ..pDatatype = pDataType;

      final result = OpenPrinter(printerNamePtr, printerHandlePtr, nullptr);
      if (result == FALSE) {
        final errorCode = GetLastError();
        PosPrinterManager.logger.error("OpenPrinter failed. Win32 Error: $errorCode");
        free(pDocName);
        free(pDataType);
        free(printerNamePtr);
        free(printerHandlePtr);
        free(docInfo);
        return ConnectionResponse.printerNotConnected;
      }

      hPrinter = printerHandlePtr.value;
      this.isConnected = true;
      this.printer.connected = true;

      // Save references for later use in writeBytes
      this.docInfo = docInfo;
      this.dwBytesWritten = calloc<DWORD>();

      // Don't free pDocName, pDataType, printerNamePtr yet — used in StartDocPrinter
      return ConnectionResponse.success;
    } catch (e) {
      PosPrinterManager.logger.error("Connect error: $e");
      return ConnectionResponse.timeout;
    }
  } else if (Platform.isAndroid) {
      var usbDevice = await usbPrinter.connect(vendorId!, productId!);
      if (usbDevice != null) {
        print("vendorId $vendorId, productId $productId ");
        this.isConnected = true;
        this.printer.connected = true;
        return Future<ConnectionResponse>.value(ConnectionResponse.success);
      } else {
        this.isConnected = false;
        this.printer.connected = false;
        return Future<ConnectionResponse>.value(ConnectionResponse.timeout);
      }
    } else {
      return Future<ConnectionResponse>.value(ConnectionResponse.timeout);
    }
  }

  /// [discover] let you explore all netWork printer in your network
  static Future<List<USBPrinter>> discover() async {
    var results = await USBService.findUSBPrinter();
    return results;
  }

  @override
  Future<ConnectionResponse> disconnect({Duration? timeout}) async {
     if (Platform.isWindows) {
    try {
      ClosePrinter(hPrinter);
      if (dwBytesWritten != null) free(dwBytesWritten!);
      if (docInfo != null) free(docInfo!);
      isConnected = false;
      printer.connected = false;
      return ConnectionResponse.success;
    } catch (e) {
      PosPrinterManager.logger.error("Disconnect error: $e");
      return ConnectionResponse.unknown;
    }
  } else if (Platform.isAndroid) {
      await usbPrinter.close();
      this.isConnected = false;
      this.printer.connected = false;
      if (timeout != null) {
        await Future.delayed(timeout, () => null);
      }
      return ConnectionResponse.success;
    }
    return ConnectionResponse.timeout;
  }

  @override
  Future<ConnectionResponse> writeBytes(List<int> data,
      {bool isDisconnect = true}) async {
    if (Platform.isWindows) {
      try {
    if (!isConnected) {
      final connectResponse = await connect();
      if (connectResponse != ConnectionResponse.success) return connectResponse;
    }

    final jobId = StartDocPrinter(hPrinter, 1, docInfo!);
    if (jobId == 0) {
      final err = GetLastError();
      PosPrinterManager.logger.error("StartDocPrinter failed. Win32 error: $err");
      ClosePrinter(hPrinter);
      return ConnectionResponse.printInProgress;
    }

    if (StartPagePrinter(hPrinter) == 0) {
      final err = GetLastError();
      PosPrinterManager.logger.error("StartPagePrinter failed. Error: $err");
      EndDocPrinter(hPrinter);
      ClosePrinter(hPrinter);
      return ConnectionResponse.printerNotSelected;
    }

    final lpData = data.toUint8();
    final byteCount = data.length;
    final result = WritePrinter(hPrinter, lpData, byteCount, dwBytesWritten!);

    if (result == 0) {
      final err = GetLastError();
      PosPrinterManager.logger.error("WritePrinter failed. Error: $err");
      EndPagePrinter(hPrinter);
      EndDocPrinter(hPrinter);
      ClosePrinter(hPrinter);
      return ConnectionResponse.printerNotWritable;
    }

    EndPagePrinter(hPrinter);
    EndDocPrinter(hPrinter);

    if (dwBytesWritten!.value != byteCount) {
      PosPrinterManager.logger.error("Only wrote ${dwBytesWritten!.value} of $byteCount bytes.");
    }

    if (isDisconnect) {
      ClosePrinter(hPrinter);
    }

    return ConnectionResponse.success;
  } catch (e) {
    PosPrinterManager.logger.error("Unexpected error: $e");
    return ConnectionResponse.unknown;
  }
    } else if (Platform.isAndroid) {
      if (!this.isConnected) {
        await connect();
        PosPrinterManager.logger.info("connect()");
      }

      PosPrinterManager.logger("start write");
      var bytes = Uint8List.fromList(data);
      int max = 16384;

      /// maxChunk limit on android
      var datas = bytes.chunkBy(max);
      await Future.forEach(
          datas, (dynamic data) async => await usbPrinter.write(data));
      PosPrinterManager.logger("end write bytes.length${bytes.length}");

      if (isDisconnect) {
        try {
          await usbPrinter.close();
          this.isConnected = false;
          this.printer.connected = false;
        } catch (e) {
          PosPrinterManager.logger.error("Error : $e");
          return ConnectionResponse.unknown;
        }
      }
      return ConnectionResponse.success;
    } else {
      return ConnectionResponse.unsupport;
    }
  }
}
