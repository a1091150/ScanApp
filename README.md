# ScanApp

This app use ARKit scan to export depth binary data, images and metadata(camera-to-world matrix) later used to train 3DGS. You can train 3DGS on Macbook with [gsplat-mlx](https://github.com/a1091150/gsplat-mlx)

## Features
- Scan data

## Dataset directory
`depth/depth_packed_hevc.mov`: quantized depth video
`metadata/frames_XXXX.jsonl`: Scanned metadata, including necessory information for 3DGS training and timestamp for video frame.
`rgb.mov`: The record of ARKit.
`session.json`: Description of the dataset.

## Note

- ARKitTrackingState may give you normal state while relocation, the relocation causes camera pose drift. 