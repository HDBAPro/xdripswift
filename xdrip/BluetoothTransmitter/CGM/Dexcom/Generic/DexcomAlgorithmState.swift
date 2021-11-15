//
//  DexcomAlgorithmState.swift
//  xdrip
//
//  Created by Johan Degraeve on 12/11/2021.
//  Copyright © 2021 Johan Degraeve. All rights reserved.
//

import Foundation

enum DexcomAlgorithmState: UInt8, CustomStringConvertible {
    
    case None = 0x00
    case SessionStopped = 0x01
    case SensorWarmup = 0x02
    case excessNoise = 0x03
    case FirstofTwoBGsNeeded = 0x04
    case SecondofTwoBGsNeeded = 0x05
    case okay = 0x06
    case needsCalibration = 0x07
    case CalibrationError1 = 0x08
    case CalibrationError2 = 0x09
    case CalibrationLinearityFitFailure = 0x0A
    case SensorFailedDuetoCountsAberration = 0x0B
    case SensorFailedDuetoResidualAberration = 0x0C
    case OutOfCalibrationDueToOutlier = 0x0D
    case OutlierCalibrationRequest = 0x0E
    case SessionExpired = 0x0F
    case SessionFailedDueToUnrecoverableError = 0x10
    case SessionFailedDueToTransmitterError = 0x11
    case TemporarySensorIssue = 0x12
    case SensorFailedDueToProgressiveSensorDecline = 0x13
    case SensorFailedDueToHighCountsAberration = 0x14
    case SensorFailedDueToLowCountsAberration = 0x15
    case SensorFailedDueToRestart = 0x16
    
    public var description: String {
        
        switch self {
            
        case .None: return "None"
        case .SessionStopped: return "SessionStopped"
        case .SensorWarmup: return "SensorWarmup"
        case .excessNoise: return "excessNoise"
        case .FirstofTwoBGsNeeded: return "FirstofTwoBGsNeeded"
        case .SecondofTwoBGsNeeded: return "SecondofTwoBGsNeeded"
        case .okay: return "InCalibration"
        case .needsCalibration: return "needsCalibration"
        case .CalibrationError1: return "CalibrationError1"
        case .CalibrationError2: return "CalibrationError2"
        case .CalibrationLinearityFitFailure: return "CalibrationLinearityFitFailure"
        case .SensorFailedDuetoCountsAberration: return "SensorFailedDuetoCountsAberration"
        case .SensorFailedDuetoResidualAberration: return "SensorFailedDuetoResidualAberration"
        case .OutOfCalibrationDueToOutlier: return "OutOfCalibrationDueToOutlier"
        case .OutlierCalibrationRequest: return "OutlierCalibrationRequest"
        case .SessionExpired: return "SessionExpired"
        case .SessionFailedDueToUnrecoverableError: return "SessionFailedDueToUnrecoverableError"
        case .SessionFailedDueToTransmitterError: return "SessionFailedDueToTransmitterError"
        case .TemporarySensorIssue: return "TemporarySensorIssue"
        case .SensorFailedDueToProgressiveSensorDecline: return "SensorFailedDueToProgressiveSensorDecline"
        case .SensorFailedDueToHighCountsAberration: return "SensorFailedDueToHighCountsAberration"
        case .SensorFailedDueToLowCountsAberration: return "SensorFailedDueToLowCountsAberration"
        case .SensorFailedDueToRestart: return "SensorFailedDueToRestart"

        }
        
    }
    
}
