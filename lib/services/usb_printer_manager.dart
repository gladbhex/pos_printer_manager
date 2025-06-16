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
  final usbPrinter = FlutterUsbPrinter();

  /// [win32]
  Pointer<DOC_INFO_1>? docInfo;
  Pointer<Uint32>? dwBytesWritten;
  late int hPrinter;

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
    generator = Generator(paperSize, profile, spaceBetweenRows: spaceBetweenRows);
  }

  @override
  Future<ConnectionResponse> connect({Duration? timeout = const Duration(seconds: 5)}) async {
    if (Platform.isWindows) {
      try {
        final printerNamePtr = printer.name!.toNativeUtf16();
        final printerHandlePtr = calloc<HANDLE>();

        final result = OpenPrinter(printerNamePtr, printerHandlePtr, nullptr);
        if (result == FALSE) {
          final errorCode = GetLastError();
          PosPrinterManager.logger.error("OpenPrinter failed. Win32 Error: $errorCode");
          free(printerNamePtr);
          free(printerHandlePtr);
          return ConnectionResponse.printerNotConnected;
        }

        hPrinter = printerHandlePtr.value;
        isConnected = true;
        printer.connected = true;

        dwBytesWritten = calloc<DWORD>();
        free(printerNamePtr);
        free(printerHandlePtr);

        return ConnectionResponse.success;
      } catch (e) {
        PosPrinterManager.logger.error("Connect error: $e");
        return ConnectionResponse.timeout;
      }
    } else if (Platform.isAndroid) {
      var usbDevice = await usbPrinter.connect(vendorId!, productId!);
      if (usbDevice != null) {
        isConnected = true;
        printer.connected = true;
        return ConnectionResponse.success;
      } else {
        isConnected = false;
        printer.connected = false;
        return ConnectionResponse.timeout;
      }
    }
    return ConnectionResponse.timeout;
  }

  /// [discover] let you explore all USB printers
  static Future<List<USBPrinter>> discover() async {
    var results = await USBService.findUSBPrinter();
    return results;
  }

  @override
  Future<ConnectionResponse> disconnect({Duration? timeout}) async {
    if (Platform.isWindows) {
      try {
        if (hPrinter != 0) ClosePrinter(hPrinter);
        if (dwBytesWritten != null) free(dwBytesWritten!);
        if (docInfo != null) {
          free(docInfo!.ref.pDocName);
          free(docInfo!.ref.pDatatype);
          free(docInfo!);
        }

        isConnected = false;
        printer.connected = false;
        return ConnectionResponse.success;
      } catch (e) {
        PosPrinterManager.logger.error("Disconnect error: $e");
        return ConnectionResponse.unknown;
      }
    } else if (Platform.isAndroid) {
      await usbPrinter.close();
      isConnected = false;
      printer.connected = false;
      if (timeout != null) {
        await Future.delayed(timeout);
      }
      return ConnectionResponse.success;
    }
    return ConnectionResponse.timeout;
  }

  @override
  Future<ConnectionResponse> writeBytes(List<int> data, {bool isDisconnect = true}) async {
    if (Platform.isWindows) {
      try {
        if (!isConnected) {
          final connectResponse = await connect();
          if (connectResponse != ConnectionResponse.success) return connectResponse;
        }

        // Allocate UTF16 strings and DOC_INFO_1
        final pDocName = 'My Document'.toNativeUtf16();
        final pDataType = 'RAW'.toNativeUtf16();
        final docInfo = calloc<DOC_INFO_1>()
          ..ref.pDocName = pDocName
          ..ref.pOutputFile = nullptr
          ..ref.pDatatype = pDataType;
        this.docInfo = docInfo;

        final jobId = StartDocPrinter(hPrinter, 1, docInfo);
        if (jobId == 0) {
          final err = GetLastError();
          PosPrinterManager.logger.error("StartDocPrinter failed. Win32 error: $err");
          ClosePrinter(hPrinter);
          free(pDocName);
          free(pDataType);
          free(docInfo);
          return ConnectionResponse.printInProgress;
        }

        if (StartPagePrinter(hPrinter) == 0) {
          final err = GetLastError();
          PosPrinterManager.logger.error("StartPagePrinter failed. Error: $err");
          EndDocPrinter(hPrinter);
          ClosePrinter(hPrinter);
          free(pDocName);
          free(pDataType);
          free(docInfo);
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
          free(pDocName);
          free(pDataType);
          free(docInfo);
          return ConnectionResponse.printerNotWritable;
        }

        EndPagePrinter(hPrinter);
        EndDocPrinter(hPrinter);

        if (dwBytesWritten!.value != byteCount) {
          PosPrinterManager.logger.error("Only wrote ${dwBytesWritten!.value} of $byteCount bytes.");
        }

        free(pDocName);
        free(pDataType);
        // Freeing docInfo happens in disconnect()

        if (isDisconnect) {
          await disconnect();
        }

        return ConnectionResponse.success;
      } catch (e) {
        PosPrinterManager.logger.error("Unexpected error: $e");
        return ConnectionResponse.unknown;
      }
    } else if (Platform.isAndroid) {
      if (!isConnected) {
        await connect();
        PosPrinterManager.logger.info("connect()");
      }

      PosPrinterManager.logger.info("start write");
      var bytes = Uint8List.fromList(data);
      int max = 16384;
      var chunks = bytes.chunkBy(max);

      await Future.forEach(chunks, (dynamic data) async {
        await usbPrinter.write(data);
      });

      PosPrinterManager.logger.info("end write, bytes.length=${bytes.length}");

      if (isDisconnect) {
        try {
          await usbPrinter.close();
          isConnected = false;
          printer.connected = false;
        } catch (e) {
          PosPrinterManager.logger.error("Error: $e");
          return ConnectionResponse.unknown;
        }
      }

      return ConnectionResponse.success;
    }

    return ConnectionResponse.unsupport;
  }
}
